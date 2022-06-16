/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
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

#pragma once

#include <cudf/column/column_device_view.cuh>
#include <cudf/detail/utilities/assert.cuh>
#include <cudf/detail/utilities/hash_functions.cuh>
#include <cudf/lists/lists_column_view.hpp>
#include <cudf/sorting.hpp>
#include <cudf/table/row_operators.cuh>
#include <cudf/table/table_device_view.cuh>
#include <cudf/utilities/traits.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <thrust/equal.h>
#include <thrust/swap.h>
#include <thrust/transform_reduce.h>

#include <limits>

namespace cudf {
namespace experimental {

template <cudf::type_id t>
struct non_nested_id_to_type {
  using type = std::conditional_t<cudf::is_nested(data_type(t)), void, id_to_type<t>>;
};

inline size_type __device__ row_to_value_idx(size_type idx, column_device_view col)
{
  while (col.type().id() == type_id::LIST or col.type().id() == type_id::STRUCT) {
    if (col.type().id() == type_id::STRUCT) {
      idx += col.offset();
      col = col.child(0);
    } else {
      auto offset_col = col.child(lists_column_view::offsets_column_index);
      idx             = offset_col.element<size_type>(idx + col.offset());
      col             = col.child(lists_column_view::child_column_index);
    }
  }
  return idx;
}

/**
 * @brief Performs a relational comparison between two elements in two columns.
 *
 * @tparam Nullate A cudf::nullate type describing how to check for nulls.
 */
template <typename Nullate>
class element_relational_comparator {
 public:
  /**
   * @brief Construct type-dispatched function object for performing a
   * relational comparison between two elements.
   *
   * @note `lhs` and `rhs` may be the same.
   *
   * @param lhs The column containing the first element
   * @param rhs The column containing the second element (may be the same as lhs)
   * @param has_nulls Indicates if either input column contains nulls.
   * @param null_precedence Indicates how null values are ordered with other values
   */
  __host__ __device__ element_relational_comparator(Nullate has_nulls,
                                                    column_device_view lhs,
                                                    column_device_view rhs,
                                                    null_order null_precedence,
                                                    int depth = std::numeric_limits<int>::max(),
                                                    size_type* dremel_offsets = nullptr,
                                                    uint8_t* rep_level        = nullptr,
                                                    uint8_t* def_level        = nullptr,
                                                    uint8_t max_def_level     = 0)
    : lhs{lhs},
      rhs{rhs},
      nulls{has_nulls},
      null_precedence{null_precedence},
      depth{depth},
      dremel_offsets{dremel_offsets},
      rep_level{rep_level},
      def_level{def_level},
      max_def_level{max_def_level}
  {
  }

  __host__ __device__ element_relational_comparator(Nullate has_nulls,
                                                    column_device_view lhs,
                                                    column_device_view rhs)
    : lhs{lhs}, rhs{rhs}, nulls{has_nulls}
  {
  }

  /**
   * @brief Performs a relational comparison between the specified elements
   *
   * @param lhs_element_index The index of the first element
   * @param rhs_element_index The index of the second element
   * @return Indicates the relationship between the elements in
   * the `lhs` and `rhs` columns.
   */
  template <typename Element,
            std::enable_if_t<cudf::is_relationally_comparable<Element, Element>()>* = nullptr>
  __device__ thrust::pair<weak_ordering, int> operator()(size_type lhs_element_index,
                                                         size_type rhs_element_index) const noexcept
  {
    if (nulls) {
      bool const lhs_is_null{lhs.is_null(lhs_element_index)};
      bool const rhs_is_null{rhs.is_null(rhs_element_index)};

      if (lhs_is_null or rhs_is_null) {  // at least one is null
        return thrust::make_pair(null_compare(lhs_is_null, rhs_is_null, null_precedence), depth);
      }
    }

    return thrust::make_pair(relational_compare(lhs.element<Element>(lhs_element_index),
                                                rhs.element<Element>(rhs_element_index)),
                             std::numeric_limits<int>::max());
  }

  template <typename Element,
            CUDF_ENABLE_IF(not cudf::is_relationally_comparable<Element, Element>() and
                           not is_nested<Element>())>
  __device__ thrust::pair<weak_ordering, int> operator()(size_type lhs_element_index,
                                                         size_type rhs_element_index)
  {
    cudf_assert(false && "Attempted to compare elements of uncomparable types.");
    return thrust::make_pair(weak_ordering::LESS, std::numeric_limits<int>::max());
  }

  template <typename Element,
            CUDF_ENABLE_IF(not cudf::is_relationally_comparable<Element, Element>() and
                           std::is_same_v<Element, cudf::struct_view>)>
  __device__ thrust::pair<weak_ordering, int> operator()(size_type lhs_element_index,
                                                         size_type rhs_element_index)
  {
    weak_ordering state{weak_ordering::EQUIVALENT};
    int last_null_depth;

    column_device_view lcol = lhs;
    column_device_view rcol = rhs;
    while (lcol.type().id() == type_id::STRUCT) {
      bool const lhs_is_null{lcol.is_null(lhs_element_index)};
      bool const rhs_is_null{rcol.is_null(rhs_element_index)};

      if (lhs_is_null or rhs_is_null) {  // atleast one is null
        state           = null_compare(lhs_is_null, rhs_is_null, null_precedence);
        last_null_depth = depth;
        return thrust::make_pair(state, last_null_depth);
      }

      lcol = lcol.children()[0];
      rcol = rcol.children()[0];
      ++depth;
    }

    if (state == weak_ordering::EQUIVALENT) {
      auto comparator = element_relational_comparator{nulls, lcol, rcol, null_precedence};
      thrust::tie(state, last_null_depth) = cudf::type_dispatcher<non_nested_id_to_type>(
        lcol.type(), comparator, lhs_element_index, rhs_element_index);
    }

    return thrust::make_pair(state, last_null_depth);
  }

  template <typename Element,
            CUDF_ENABLE_IF(not cudf::is_relationally_comparable<Element, Element>() and
                           std::is_same_v<Element, cudf::list_view>)>
  __device__ thrust::pair<weak_ordering, int> operator()(size_type lhs_element_index,
                                                         size_type rhs_element_index)
  {
    auto l_start            = dremel_offsets[lhs_element_index];
    auto l_end              = dremel_offsets[lhs_element_index + 1];
    auto r_start            = dremel_offsets[rhs_element_index];
    auto r_end              = dremel_offsets[rhs_element_index + 1];
    auto lc_start           = row_to_value_idx(lhs_element_index, lhs);
    auto rc_start           = row_to_value_idx(rhs_element_index, rhs);
    column_device_view lcol = lhs;
    column_device_view rcol = rhs;
    while (lcol.type().id() == type_id::LIST) {
      lcol = lcol.child(lists_column_view::child_column_index);
      rcol = rcol.child(lists_column_view::child_column_index);
    }
    // printf("max_def_level: %d\n", max_def_level);

    // printf("t: %d, lhs_element_index: %d, rhs_element_index: %d\n",
    //        threadIdx.x,
    //        lhs_element_index,
    //        rhs_element_index);
    // printf("t: %d, l_start: %d, l_end: %d, r_start: %d, r_end: %d\n",
    //        threadIdx.x,
    //        l_start,
    //        l_end,
    //        r_start,
    //        r_end);
    weak_ordering state{weak_ordering::EQUIVALENT};
    for (int i = l_start, j = r_start, m = lc_start, n = rc_start; i < l_end and j < r_end;
         ++i, ++j) {
      // printf("t: %d, i: %d, j: %d, m: %d, n: %d\n", threadIdx.x, i, j, m, n);
      // printf("t: %d, def_l: %d, def_r: %d, rep_l: %d, rep_r: %d\n",
      //        threadIdx.x,
      //        def_level[i],
      //        def_level[j],
      //        rep_level[i],
      //        rep_level[j]);
      if (def_level[i] != def_level[j]) {
        state = (def_level[i] < def_level[j]) ? weak_ordering::LESS : weak_ordering::GREATER;
        // printf("t: %d, def, state: %d\n", threadIdx.x, state);
        return thrust::make_pair(state, depth);
      }
      if (rep_level[i] != rep_level[j]) {
        state = (rep_level[i] < rep_level[j]) ? weak_ordering::LESS : weak_ordering::GREATER;
        // printf("t: %d, rep, state: %d\n", threadIdx.x, state);
        return thrust::make_pair(state, depth);
      }
      if (def_level[i] == max_def_level) {
        auto comparator = element_relational_comparator{nulls, lcol, rcol, null_precedence};
        thrust::tie(state, depth) =
          cudf::type_dispatcher<non_nested_id_to_type>(lcol.type(), comparator, m, n);
        if (state != weak_ordering::EQUIVALENT) {
          // printf("t: %d, leaf, state: %d\n", threadIdx.x, state);
          return thrust::make_pair(state, depth);
        }
        ++m;
        ++n;
      }
    }
    state = (l_end - l_start < r_end - r_start)   ? weak_ordering::LESS
            : (l_end - l_start > r_end - r_start) ? weak_ordering::GREATER
                                                  : weak_ordering::EQUIVALENT;
    return thrust::make_pair(state, depth);
  }

 private:
  column_device_view lhs;
  column_device_view rhs;
  Nullate nulls;
  null_order null_precedence{};
  int depth{std::numeric_limits<int>::max()};
  size_type* dremel_offsets;
  uint8_t* rep_level;
  uint8_t* def_level;
  uint8_t* max_def_levels;
  uint8_t max_def_level{0};
};

/**
 * @brief Computes whether one row is lexicographically *less* than another row.
 *
 * Lexicographic ordering is determined by:
 * - Two rows are compared element by element.
 * - The first mismatching element defines which row is lexicographically less
 * or greater than the other.
 *
 * Lexicographic ordering is exactly equivalent to doing an alphabetical sort of
 * two words, for example, `aac` would be *less* than (or precede) `abb`. The
 * second letter in both words is the first non-equal letter, and `a < b`, thus
 * `aac < abb`.
 *
 * @tparam Nullate A cudf::nullate type describing how to check for nulls.
 */
template <typename Nullate>
class row_lexicographic_comparator {
 public:
  /**
   * @brief Construct a function object for performing a lexicographic
   * comparison between the rows of two tables.
   *
   * @throws cudf::logic_error if `lhs.num_columns() != rhs.num_columns()`
   * @throws cudf::logic_error if column types of `lhs` and `rhs` are not comparable.
   *
   * @param lhs The first table
   * @param rhs The second table (may be the same table as `lhs`)
   * @param has_nulls Indicates if either input table contains columns with nulls.
   * @param column_order Optional, device array the same length as a row that
   * indicates the desired ascending/descending order of each column in a row.
   * If `nullptr`, it is assumed all columns are sorted in ascending order.
   * @param null_precedence Optional, device array the same length as a row
   * and indicates how null values compare to all other for every column. If
   * it is nullptr, then null precedence would be `null_order::BEFORE` for all
   * columns.
   */
  row_lexicographic_comparator(Nullate has_nulls,
                               table_device_view lhs,
                               table_device_view rhs,
                               int const* depth                  = nullptr,
                               order const* column_order         = nullptr,
                               null_order const* null_precedence = nullptr,
                               size_type** dremel_offsets        = nullptr,
                               uint8_t** rep_levels              = nullptr,
                               uint8_t** def_levels              = nullptr,
                               uint8_t* max_def_levels           = nullptr)
    : _lhs{lhs},
      _rhs{rhs},
      _nulls{has_nulls},
      _depth{depth},
      _column_order{column_order},
      _null_precedence{null_precedence},
      _dremel_offsets{dremel_offsets},
      _rep_levels{rep_levels},
      _def_levels{def_levels},
      _max_def_levels{max_def_levels}
  {
    CUDF_EXPECTS(_lhs.num_columns() == _rhs.num_columns(), "Mismatched number of columns.");
    // CUDF_EXPECTS(detail::is_relationally_comparable(_lhs, _rhs),
    //              "Attempted to compare elements of uncomparable types.");
  }

  /**
   * @brief Checks whether the row at `lhs_index` in the `lhs` table compares
   * lexicographically less than the row at `rhs_index` in the `rhs` table.
   *
   * @param lhs_index The index of row in the `lhs` table to examine
   * @param rhs_index The index of the row in the `rhs` table to examine
   * @return `true` if row from the `lhs` table compares less than row in the
   * `rhs` table
   */
  __device__ bool operator()(size_type lhs_index, size_type rhs_index) const noexcept
  {
    int last_null_depth = std::numeric_limits<int>::max();
    for (size_type i = 0; i < _lhs.num_columns(); ++i) {
      int depth = _depth == nullptr ? std::numeric_limits<int>::max() : _depth[i];
      if (depth > last_null_depth) { continue; }

      bool ascending = (_column_order == nullptr) or (_column_order[i] == order::ASCENDING);

      null_order null_precedence =
        _null_precedence == nullptr ? null_order::BEFORE : _null_precedence[i];

      auto comparator = element_relational_comparator{_nulls,
                                                      _lhs.column(i),
                                                      _rhs.column(i),
                                                      null_precedence,
                                                      depth,
                                                      _dremel_offsets[i],
                                                      _rep_levels[i],
                                                      _def_levels[i],
                                                      _max_def_levels[i]};

      weak_ordering state;
      thrust::tie(state, last_null_depth) =
        cudf::type_dispatcher(_lhs.column(i).type(), comparator, lhs_index, rhs_index);

      if (state == weak_ordering::EQUIVALENT) { continue; }

      return state == (ascending ? weak_ordering::LESS : weak_ordering::GREATER);
    }
    return false;
  }

 private:
  table_device_view _lhs;
  table_device_view _rhs;
  Nullate _nulls{};
  null_order const* _null_precedence{};
  order const* _column_order{};
  int const* _depth;
  size_type** _dremel_offsets;
  uint8_t** _rep_levels;
  uint8_t** _def_levels;
  uint8_t* _max_def_levels;
};  // class row_lexicographic_comparator

/**
 * @brief Dremel data that describes one nested type column
 *
 * @see get_dremel_data()
 */
struct dremel_data {
  rmm::device_uvector<size_type> dremel_offsets;
  rmm::device_uvector<uint8_t> rep_level;
  rmm::device_uvector<uint8_t> def_level;

  size_type leaf_data_size;
};

struct row_lex_operator {
  row_lex_operator(table_view const& lhs,
                   table_view const& rhs,
                   host_span<order const> column_order,
                   host_span<null_order const> null_precedence,
                   rmm::cuda_stream_view stream);

  row_lex_operator(table_view const& t,
                   host_span<order const> column_order,
                   host_span<null_order const> null_precedence,
                   rmm::cuda_stream_view stream);

  template <typename Nullate>
  row_lexicographic_comparator<Nullate> device_comparator()
  {
    auto lhs = **d_lhs;
    auto rhs = (d_rhs ? **d_rhs : **d_lhs);
    if constexpr (std::is_same_v<Nullate, nullate::DYNAMIC>) {
      return row_lexicographic_comparator(Nullate{any_nulls},
                                          lhs,
                                          rhs,
                                          d_depths.data(),
                                          d_column_order.data(),
                                          d_null_precedence.data(),
                                          d_dremel_offsets.data(),
                                          d_rep_levels.data(),
                                          d_def_levels.data(),
                                          d_max_def_levels.data());
    } else {
      return row_lexicographic_comparator<Nullate>(
        Nullate{}, lhs, rhs, d_depths.data(), d_column_order.data(), d_null_precedence.data());
    }
  }

 private:
  using table_device_view_owner =
    std::invoke_result_t<decltype(table_device_view::create), table_view, rmm::cuda_stream_view>;

  std::unique_ptr<table_device_view_owner> d_lhs;
  std::unique_ptr<table_device_view_owner> d_rhs;
  rmm::device_uvector<order> d_column_order;
  rmm::device_uvector<null_order> d_null_precedence;
  rmm::device_uvector<size_type> d_depths;

  // List related pre-computation
  std::vector<dremel_data> dremel_data;
  rmm::device_uvector<size_type*> d_dremel_offsets;
  rmm::device_uvector<uint8_t*> d_rep_levels;
  rmm::device_uvector<uint8_t*> d_def_levels;
  rmm::device_uvector<uint8_t> d_max_def_levels;
  bool any_nulls;
};

}  // namespace experimental
}  // namespace cudf