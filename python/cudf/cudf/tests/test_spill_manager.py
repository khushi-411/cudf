# Copyright (c) 2022, NVIDIA CORPORATION.


import warnings

import pytest

import rmm

import cudf
from cudf.core.buffer import Buffer
from cudf.core.spill_manager import SpillManager, global_manager


def gen_df() -> cudf.DataFrame:
    return cudf.DataFrame({"a": [1, 2, 3]})


gen_df.buffer_size = 24


@pytest.fixture
def manager(request):
    kwargs = dict(getattr(request, "param", {}))
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        try:
            yield global_manager.reset(SpillManager(**kwargs))
        finally:
            global_manager.clear()


def test_spillable_buffer():
    buf = Buffer(rmm.DeviceBuffer(size=10), sole_owner=True)
    assert buf.spillable
    buf.ptr  # Expose pointer
    assert buf._raw_pointer_exposed
    assert not buf.spillable
    buf = Buffer(rmm.DeviceBuffer(size=10), sole_owner=True)
    buf.__cuda_array_interface__  # Expose pointer
    assert buf._raw_pointer_exposed
    assert not buf.spillable


def test_spillable_df_creation():
    df = cudf.datasets.timeseries()
    assert df._data._data["x"].data.spillable
    df = cudf.DataFrame({"x": [1, 2, 3]})
    assert df._data._data["x"].data.spillable
    df = cudf.datasets.randomdata(10)
    assert df._data._data["x"].data.spillable


def test_spillable_df_groupby():
    df = cudf.DataFrame({"x": [1, 1, 1]})
    gb = df.groupby("x")
    # `gd` holds a reference to the device memory, which makes
    # the buffer unspillable
    assert df._data._data["x"].data._access_counter.use_count() == 2
    assert not df._data._data["x"].data.spillable
    del gb
    assert df._data._data["x"].data.spillable


def test_spilling_buffer():
    buf = Buffer(rmm.DeviceBuffer(size=10), sole_owner=True)
    buf.move_inplace(target="cpu")
    assert buf.is_spilled
    buf.ptr  # Expose pointer and trigger unspill
    assert not buf.is_spilled
    with pytest.raises(ValueError, match="unspillable buffer"):
        buf.move_inplace(target="cpu")


def test_manager(manager: SpillManager):
    df = gen_df()
    assert manager.spilled_and_unspilled() == (0, gen_df.buffer_size)
    manager.spill_device_memory()
    assert manager.spilled_and_unspilled() == (gen_df.buffer_size, 0)
    del df
    assert manager.spilled_and_unspilled() == (0, 0)


def test_spill_to_device_limit(manager: SpillManager):
    df1 = gen_df()
    df2 = gen_df()
    assert manager.spilled_and_unspilled() == (0, gen_df.buffer_size * 2)
    manager.spill_to_device_limit(device_limit=0)
    assert manager.spilled_and_unspilled() == (gen_df.buffer_size * 2, 0)
    df3 = df1 + df2
    manager.spill_to_device_limit(device_limit=0)
    assert manager.spilled_and_unspilled() == (gen_df.buffer_size * 3, 0)
    assert df1._data._data["a"].data.is_spilled
    assert df2._data._data["a"].data.is_spilled
    assert df3._data._data["a"].data.is_spilled
