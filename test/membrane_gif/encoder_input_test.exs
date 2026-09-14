defmodule Membrane.GIF.Encoder.InputTest do
  use ExUnit.Case, async: false

  alias Membrane.GIF.Encoder.Native
  alias Membrane.GIF.Test.AllocationLimit

  @frame_sizes [
    I420: 192,
    I422: 256,
    I444: 384,
    RGB: 384,
    BGR: 384,
    RGBA: 512,
    BGRA: 512,
    NV12: 192,
    NV21: 192,
    YUY2: 256
  ]

  for {format, size} <- @frame_sizes,
      {kind, bad_size} <- [empty: 0, truncated: size - 1, oversized: size + 1] do
    test "#{format}: #{kind} input returns invalid_frame_size before encoding" do
      assert {:ok, state} = Native.create(16, 8, unquote(format))

      assert {:error, :invalid_frame_size} =
               Native.encode(:binary.copy(<<128>>, unquote(bad_size)), state)

      frame = :binary.copy(<<128>>, unquote(size))
      assert {:ok, packets} = Native.encode(frame, state)
      assert {:ok, fresh} = Native.create(16, 8, unquote(format))
      assert {:ok, ^packets} = Native.encode(frame, fresh)
      assert {:ok, []} = Native.flush(state)
      assert {:ok, []} = Native.flush(fresh)
    end
  end

  for {format, size} <- @frame_sizes do
    test "#{format}: conversion reaches frame submission under a one-byte allocation limit" do
      assert {:ok, state} = Native.create(16, 8, unquote(format))
      frame = :binary.copy(<<128>>, unquote(size))

      assert {:error, :send_frame} =
               AllocationLimit.with_limit(1, fn -> Native.encode(frame, state) end)
    end
  end

  test "invalid dimensions are rejected at initialization" do
    for {width, height} <- [{0, 8}, {16, 0}, {-1, 8}, {65_536, 8}] do
      assert {:error, :codec_open} = Native.create(width, height, :RGB)
    end
  end

  test "unsupported format is rejected by the generated interface" do
    error = assert_raise ErlangError, fn -> Native.create(16, 8, :GRAY16) end
    assert error.original == {:unifex_parse_arg, {:pix_fmt, ~c":pixel_format"}}
  end
end
