defmodule Membrane.GIF.Encoder.AllocationTest do
  # av_max_alloc is global to the linked libavutil. ExUnit runs synchronous
  # modules after asynchronous tests; always restore the limit in an after block.
  use ExUnit.Case, async: false

  alias Membrane.GIF.Encoder.Native
  alias Membrane.GIF.Test.AllocationLimit

  @frame :binary.copy(<<128>>, 16 * 8 * 3)

  test "resource cleanup accepts a NULL encoder after real allocation failure" do
    # av_mallocz fails under this limit, leaving state->encoder NULL. create()
    # returns an error and releases its resource; Unifex calls
    # handle_destroy_state(), which reaches destroy_encoder(NULL).
    assert {:error, :encoder_alloc} =
             AllocationLimit.with_limit(1, fn -> Native.create(16, 8, :RGB) end)

    assert {:ok, state} = Native.create(16, 8, :RGB)
    assert {:ok, [_packet]} = Native.encode(@frame, state)
    assert {:ok, []} = Native.flush(state)
  end

  test "real FFmpeg context allocation fails after allocating GIFEncoder" do
    assert {:error, :codec_alloc} =
             AllocationLimit.with_limit(512, fn -> Native.create(16, 8, :RGB) end)

    assert {:ok, _state} = Native.create(16, 8, :RGB)
  end

  test "real GIF encoder initialization exceeds a 4 KiB allocation limit" do
    assert {:error, :codec_open} =
             AllocationLimit.with_limit(4096, fn -> Native.create(16, 8, :RGB) end)
  end

  test "padded frame storage exceeds the limit after GIF initialization succeeds" do
    # GIF working allocations fit within 200,000 bytes.
    # The aligned 1x8192 frame requires a larger allocation.
    assert {:error, :frame_buffer} =
             AllocationLimit.with_limit(200_000, fn -> Native.create(1, 8192, :RGB) end)

    assert {:ok, _state} = Native.create(1, 8192, :RGB)
  end

  test "real FFmpeg frame submission fails when internal allocations are limited" do
    assert {:ok, state} = Native.create(16, 8, :RGB)

    assert {:error, :send_frame} =
             AllocationLimit.with_limit(1, fn -> Native.encode(@frame, state) end)
  end

  test "copy-on-write allocation fails after GIF retains the previous frame" do
    assert {:ok, state} = Native.create(16, 8, :RGB)
    assert {:ok, [_packet]} = Native.encode(@frame, state)

    assert {:error, :frame_writable} =
             AllocationLimit.with_limit(1, fn -> Native.encode(@frame, state) end)

    assert {:ok, [_packet]} = Native.encode(@frame, state)
    assert {:ok, []} = Native.flush(state)
  end

  test "real packet allocation fails while collecting flush output" do
    assert {:ok, state} = Native.create(16, 8, :RGB)

    assert {:error, :encode} =
             AllocationLimit.with_limit(1, fn -> Native.flush(state) end)
  end

  test "the allocation limit is restored even when the test body raises" do
    assert_raise RuntimeError, "test failure", fn ->
      AllocationLimit.with_limit(1, fn -> raise "test failure" end)
    end

    assert {:ok, state} = Native.create(16, 8, :RGB)
    assert {:ok, [_packet]} = Native.encode(@frame, state)
  end
end
