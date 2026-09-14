defmodule Membrane.GIF.Encoder.InputTest do
  use ExUnit.Case, async: true

  alias Membrane.GIF.Encoder.Native
  alias Membrane.GIF.Test.GIFBlocks

  @options %{
    width: 16,
    height: 8,
    pixel_format: :RGB,
    loop: nil
  }

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
    YUY2: 256,
    YV12: 192,
    AYUV: 512,
    I420_10LE: 384,
    I420_10BE: 384,
    I422_10LE: 512,
    I422_10BE: 512,
    I444_10LE: 768,
    I444_10BE: 768
  ]

  for {format, size} <- @frame_sizes,
      {kind, bad_size} <- [empty: 0, truncated: size - 1, oversized: size + 1] do
    test "#{format}: #{kind} input returns invalid_frame_size before encoding" do
      assert {:ok, state} =
               Native.create(%{@options | pixel_format: unquote(format)})

      assert {:error, "invalid_frame_size"} =
               Native.encode(state, :binary.copy(<<128>>, unquote(bad_size)), 4)

      # Repeated 0x01 bytes represent valid 8-bit samples and 10-bit words (257).
      frame = :binary.copy(<<1>>, unquote(size))
      assert {:ok, chunk} = Native.encode(state, frame, 4)
      assert {:ok, <<0x3B>>} = Native.finish(state)
      assert %{width: 16, height: 8, images: 1, delays: [4]} = GIFBlocks.parse(chunk <> <<0x3B>>)

      assert {:ok, fresh} =
               Native.create(%{@options | pixel_format: unquote(format)})

      assert {:ok, ^chunk} = Native.encode(fresh, frame, 4)
      assert {:ok, <<0x3B>>} = Native.finish(fresh)
    end
  end

  for {le, be, chroma_samples} <- [
        {:I420_10LE, :I420_10BE, 2},
        {:I422_10LE, :I422_10BE, 4},
        {:I444_10LE, :I444_10BE, 8}
      ] do
    test "#{le} and #{be} preserve byte order through the real NIF" do
      samples =
        [64, 64, 940, 940, 64, 64, 940, 940] ++
          List.duplicate(512, unquote(chroma_samples) * 2)

      little_endian = for sample <- samples, into: <<>>, do: <<sample::16-little>>
      big_endian = for sample <- samples, into: <<>>, do: <<sample::16-big>>
      refute little_endian == big_endian

      assert {:ok, le_encoder} =
               Native.create(%{@options | width: 4, height: 2, pixel_format: unquote(le)})

      assert {:ok, be_encoder} =
               Native.create(%{@options | width: 4, height: 2, pixel_format: unquote(be)})

      assert {:ok, gif} = Native.encode(le_encoder, little_endian, 4)
      assert {:ok, ^gif} = Native.encode(be_encoder, big_endian, 4)
      assert {:ok, rgb_encoder} = Native.create(%{@options | width: 4, height: 2})
      rgb = :binary.copy(<<0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255>>, 2)
      assert {:ok, ^gif} = Native.encode(rgb_encoder, rgb, 4)
      assert {:ok, <<0x3B>>} = Native.finish(le_encoder)
      assert {:ok, <<0x3B>>} = Native.finish(be_encoder)
      assert {:ok, <<0x3B>>} = Native.finish(rgb_encoder)
      assert %{images: 1, delays: [4]} = GIFBlocks.parse(gif <> <<0x3B>>)
    end
  end

  test "YV12 swaps chroma planes relative to I420 through the real NIF" do
    y = <<81, 81, 41, 41, 81, 81, 41, 41>>
    u = <<90, 240>>
    v = <<240, 110>>
    assert {:ok, i420} = Native.create(%{@options | width: 4, height: 2, pixel_format: :I420})
    assert {:ok, yv12} = Native.create(%{@options | width: 4, height: 2, pixel_format: :YV12})
    assert {:ok, gif} = Native.encode(i420, y <> u <> v, 4)
    assert {:ok, ^gif} = Native.encode(yv12, y <> v <> u, 4)
    assert {:ok, <<0x3B>>} = Native.finish(i420)
    assert {:ok, <<0x3B>>} = Native.finish(yv12)
  end

  test "AYUV channel order and discarded alpha match opaque RGB through the real NIF" do
    pixels =
      :binary.copy(
        <<0, 16, 128, 128, 127, 16, 128, 128, 255, 235, 128, 128, 0, 235, 128, 128>>,
        2
      )

    rgb = :binary.copy(<<0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255>>, 2)
    assert {:ok, ayuv} = Native.create(%{@options | width: 4, height: 2, pixel_format: :AYUV})
    assert {:ok, rgb_encoder} = Native.create(%{@options | width: 4, height: 2})
    assert {:ok, gif} = Native.encode(ayuv, pixels, 4)
    assert {:ok, ^gif} = Native.encode(rgb_encoder, rgb, 4)
    assert {:ok, <<0x3B>>} = Native.finish(ayuv)
    assert {:ok, <<0x3B>>} = Native.finish(rgb_encoder)
  end

  test "native argument conversion rejects dimensions outside u16" do
    for {width, height, exception} <- [
          {-1, 8, ErlangError},
          {16, -1, ErlangError},
          {65_536, 8, ArgumentError},
          {16, 65_536, ArgumentError},
          {0.5, 8, ErlangError},
          {16, :unknown, ErlangError}
        ] do
      assert_raise exception, fn ->
        Native.create(%{@options | width: width, height: height})
      end
    end
  end

  test "pixel-format decoding preserves exact Membrane atom names" do
    for format <- [:GRAY16, :i420, :rgb, :nv12] do
      assert {:error, "unsupported_pixel_format"} =
               Native.create(%{@options | pixel_format: format})
    end
  end

  test "native argument conversion rejects out-of-range delays before encoding" do
    assert {:ok, state} = Native.create(@options)

    for delay <- [-1, 65_536] do
      assert_raise ArgumentError, fn ->
        Native.encode(state, :binary.copy(<<128>>, 384), delay)
      end
    end

    assert {:ok, chunk} = Native.encode(state, :binary.copy(<<128>>, 384), 1)
    assert {:ok, <<0x3B>>} = Native.finish(state)
    assert %{images: 1, delays: [1]} = GIFBlocks.parse(chunk <> <<0x3B>>)
  end

  test "native argument conversion rejects repeat counts outside u16" do
    for {loop, exception} <- [{-1, ErlangError}, {65_536, ArgumentError}] do
      assert_raise exception, fn -> Native.create(%{@options | loop: loop}) end
    end
  end

  test "native encode requires an integer delay in centiseconds" do
    assert {:ok, state} = Native.create(@options)

    for delay <- [nil, 0.5, :unknown] do
      assert_raise ArgumentError, fn ->
        Native.encode(state, :binary.copy(<<128>>, 384), delay)
      end
    end
  end

  test "finishing empty input emits no GIF bytes" do
    assert {:ok, state} = Native.create(@options)
    assert {:ok, <<>>} = Native.finish(state)
  end

  test "a resource can be handed to another BEAM process" do
    assert {:ok, state} = Native.create(@options)

    task = Task.async(fn -> Native.encode(state, :binary.copy(<<128>>, 384), 10) end)
    assert {:ok, chunk} = Task.await(task)
    assert {:ok, <<0x3B>>} = Native.finish(state)
    assert %{images: 1, delays: [10]} = GIFBlocks.parse(chunk <> <<0x3B>>)
  end

  test "each encode call returns its frame and finish returns only the trailer" do
    assert {:ok, state} =
             Native.create(%{
               width: 4,
               height: 2,
               pixel_format: :RGB,
               loop: 7
             })

    frame = :binary.copy(<<255, 0, 0>>, 8)
    assert {:ok, first} = Native.encode(state, frame, 3)

    assert %{width: 4, height: 2, images: 1, loop: 7, delays: [3]} =
             GIFBlocks.parse(first <> <<0x3B>>)

    assert {:ok, last} = Native.encode(state, frame, 5)
    assert {:ok, <<0x3B>>} = Native.finish(state)

    assert %{width: 4, height: 2, images: 2, loop: 7, delays: [3, 5]} =
             GIFBlocks.parse(first <> last <> <<0x3B>>)
  end

  test "every option key is required, including keys whose values may be nil" do
    for key <- Map.keys(@options) do
      assert_raise ArgumentError, fn -> Native.create(Map.delete(@options, key)) end
    end
  end
end
