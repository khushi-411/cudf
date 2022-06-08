/*
 * Copyright (c) 2019-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "stream_compaction_common.cuh"

#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/copy.hpp>
#include <cudf/detail/copy_if.cuh>
#include <cudf/detail/gather.cuh>
#include <cudf/detail/gather.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/sorting.hpp>
#include <cudf/detail/stream_compaction.hpp>
#include <cudf/stream_compaction.hpp>
#include <cudf/table/experimental/row_operators.cuh>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/copy.h>
#include <thrust/execution_policy.h>
#include <thrust/functional.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/discard_iterator.h>

#include <utility>
#include <vector>

namespace cudf {
namespace detail {

namespace {
template <typename MapDeviceView, typename Hash, typename KeyEqual>
struct reduce_fn_gen {
  __device__ size_type& inserted_value(size_type const idx) const
  {
    // iter should always be valid, because all keys have been inserted.
    auto const iter = d_map.find(idx, d_hash, d_eqcomp);

    // Here idx is the index of the unique elements that has been inserted into the map.
    // As such, `find` calling for all duplicate keys will return the same idx value.
    auto const inserted_idx = iter->second.load(cuda::std::memory_order_relaxed);

    return d_output[inserted_idx];
  }

  template <duplicate_keep_option keep>
  struct reduce_index_fn {
    __device__ void operator()(size_type const idx) const
    {
      if constexpr (keep == duplicate_keep_option::KEEP_FIRST) {
        // Store the smallest index of all keys that are equal.
        atomicMin(&parent.inserted_value(idx), idx);
      } else if constexpr (keep == duplicate_keep_option::KEEP_LAST) {
        // Store the greatest index of all keys that are equal.
        atomicMax(&parent.inserted_value(idx), idx);
      } else {
        // Count the number of duplicates for key.
        atomicAdd(&parent.inserted_value(idx), size_type{1});
      }
    }

    reduce_fn_gen const parent;
  };

  template <duplicate_keep_option keep>
  auto reduce_fn() const
  {
    return reduce_index_fn<keep>{*this};
  }

  size_type* const d_output;
  MapDeviceView const d_map;
  Hash const d_hash;
  KeyEqual const d_eqcomp;
};

}  // namespace

// todo: add doxygen and detail interface
// this will be userful for many follow up pr
rmm::device_uvector<size_type> distinct_map(table_view const& input,
                                            std::vector<size_type> const& keys,
                                            duplicate_keep_option keep,
                                            null_equality nulls_equal,
                                            rmm::cuda_stream_view stream,
                                            rmm::mr::device_memory_resource* mr)
{
  if (input.num_rows() == 0 or input.num_columns() == 0 or keys.empty()) {
    return rmm::device_uvector<size_type>(0, stream);
  }

  auto const keys_tview = input.select(keys);
  auto const preprocessed_keys =
    cudf::experimental::row::hash::preprocessed_table::create(keys_tview, stream);
  auto const has_null  = nullate::DYNAMIC{cudf::has_nested_nulls(keys_tview)};
  auto const keys_size = keys_tview.num_rows();

  auto key_map = hash_map_type{compute_hash_table_size(keys_size),
                               COMPACTION_EMPTY_KEY_SENTINEL,
                               COMPACTION_EMPTY_VALUE_SENTINEL,
                               detail::hash_table_allocator_type{default_allocator<char>{}, stream},
                               stream.value()};

  auto const row_hash = cudf::experimental::row::hash::row_hasher(preprocessed_keys);
  auto const hash_key = experimental::compaction_hash(row_hash.device_hasher(has_null));

  auto const row_comp  = cudf::experimental::row::equality::self_comparator(preprocessed_keys);
  auto const key_equal = row_comp.device_comparator(has_null, nulls_equal);

  auto const kv_iter = cudf::detail::make_counting_transform_iterator(
    size_type{0}, [] __device__(size_type const i) { return cuco::make_pair(i, i); });
  key_map.insert(kv_iter, kv_iter + keys_size, hash_key, key_equal, stream.value());

  auto distinct_map = rmm::device_uvector<size_type>(key_map.get_size(), stream, mr);
  // If we don't care about order, just gather all rows having distinct keys taken from key_map.
  if (keep == duplicate_keep_option::KEEP_ANY) {
    key_map.retrieve_all(distinct_map.begin(), thrust::make_discard_iterator(), stream.value());
    return distinct_map;
  }

  auto const init_value = [keep] {
    if (keep == duplicate_keep_option::KEEP_FIRST) {
      return std::numeric_limits<size_type>::max();
    } else if (keep == duplicate_keep_option::KEEP_LAST) {
      return std::numeric_limits<size_type>::min();
    }
    return size_type{0};  // keep == KEEP_NONE
  }();

  auto reduced_indices = rmm::device_uvector<size_type>(keys_tview.num_rows(), stream);
  thrust::uninitialized_fill(
    rmm::exec_policy(stream), reduced_indices.begin(), reduced_indices.end(), init_value);

  auto const d_map  = key_map.get_device_view();
  auto const fn_gen = reduce_fn_gen<decltype(d_map), decltype(hash_key), decltype(key_equal)>{
    reduced_indices.begin(), d_map, hash_key, key_equal};

  auto const do_reduce = [keys_size, stream](auto const& fn) {
    thrust::for_each(rmm::exec_policy(stream),
                     thrust::counting_iterator<size_type>(0),
                     thrust::counting_iterator<size_type>(keys_size),
                     fn);
  };
  switch (keep) {
    case duplicate_keep_option::KEEP_FIRST:
      do_reduce(fn_gen.reduce_fn<duplicate_keep_option::KEEP_FIRST>());
      break;
    case duplicate_keep_option::KEEP_LAST:
      do_reduce(fn_gen.reduce_fn<duplicate_keep_option::KEEP_LAST>());
      break;
    case duplicate_keep_option::KEEP_NONE:
      do_reduce(fn_gen.reduce_fn<duplicate_keep_option::KEEP_NONE>());
      break;
    default:;  // KEEP_ANY has already been handled
  }

  // Filter out the indices of the duplicate keys except one (so to keep one).
  auto const copy_output_indicies = [&](auto const& fn) {
    return thrust::copy_if(rmm::exec_policy(stream),
                           reduced_indices.begin(),
                           reduced_indices.end(),
                           distinct_map.begin(),
                           fn);
  };
  auto const map_end = [&] {
    if (keep == duplicate_keep_option::KEEP_NONE) {
      return copy_output_indicies(
        [reduced_indices = reduced_indices.begin()] __device__(auto const idx) {
          return reduced_indices[idx] == size_type{1};
        });
    }
    return copy_output_indicies(
      [init_value] __device__(auto const idx) { return idx != init_value; });
  }();

  distinct_map.resize(thrust::distance(distinct_map.begin(), map_end), stream);
  return distinct_map;
}

std::unique_ptr<table> distinct(table_view const& input,
                                std::vector<size_type> const& keys,
                                duplicate_keep_option keep,
                                null_equality nulls_equal,
                                rmm::cuda_stream_view stream,
                                rmm::mr::device_memory_resource* mr)
{
  if (input.num_rows() == 0 or input.num_columns() == 0 or keys.empty()) {
    return empty_like(input);
  }

  auto const gather_map =
    distinct_map(input, keys, keep, nulls_equal, stream, rmm::mr::get_current_device_resource());
  return detail::gather(
    input, gather_map.begin(), gather_map.end(), out_of_bounds_policy::DONT_CHECK, stream, mr);
}

}  // namespace detail

std::unique_ptr<table> distinct(table_view const& input,
                                std::vector<size_type> const& keys,
                                duplicate_keep_option keep,
                                null_equality nulls_equal,
                                rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::distinct(input, keys, keep, nulls_equal, rmm::cuda_stream_default, mr);
}

}  // namespace cudf
