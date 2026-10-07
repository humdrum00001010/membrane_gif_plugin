defmodule Membrane.GIF.EncoderTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.GIF
  alias Membrane.GIF.Encoder
  alias Membrane.GIF.Test.GIFBlocks
  alias Membrane.RawVideo
  alias Membrane.Testing

  @frame :binary.copy(<<128>>, 16 * 8 * 3)
  @format %RawVideo{width: 16, height: 8, pixel_format: :RGB, aligned: true, framerate: nil}

  defp frame(pts, payload \\ @frame), do: %Buffer{payload: payload, pts: pts}

  defp start_pipeline(frames, format \\ @format, encoder \\ Encoder) do
    Testing.Pipeline.start_link_supervised!(
      spec:
        child(:source, %Testing.Source{stream_format: format, output: frames})
        |> child(:encoder, encoder)
        |> child(:sink, Testing.Sink)
    )
  end

  test "pipeline emits timed GIF chunks with a loop extension and trailer" do
    pipeline =
      start_pipeline(
        [frame(1_000_000_000), frame(1_070_000_000), frame(1_160_000_000)],
        @format,
        %Encoder{loop: 2, last_frame_duration: 50_000_000}
      )

    assert_sink_stream_format(pipeline, :sink, %GIF{width: 16, height: 8})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_000_000_000, payload: first})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_070_000_000, payload: second})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_160_000_000, payload: third})
    assert_end_of_stream(pipeline, :sink)

    assert %{width: 16, height: 8, images: 3, loop: 2, delays: [7, 9, 5]} =
             GIFBlocks.parse(first <> second <> third)
  end

  test "rounds cumulative PTS boundaries with default or omitted looping" do
    for {encoder, loop} <- [{Encoder, 0}, {%Encoder{loop: nil}, nil}] do
      pipeline =
        start_pipeline([frame(0), frame(33_333_333), frame(66_666_666)], @format, encoder)

      assert_sink_stream_format(pipeline, :sink, %GIF{width: 16, height: 8})
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0, payload: first})
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 33_333_333, payload: second})
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 66_666_666, payload: third})
      assert_end_of_stream(pipeline, :sink)

      assert %{images: 3, delays: [3, 4, 3], loop: ^loop} =
               GIFBlocks.parse(first <> second <> third)
    end
  end

  test "pipeline encodes zero and nonzero RGBA alpha and finalizes its GIF" do
    format = %{@format | width: 6, height: 1, pixel_format: :RGBA}
    pixels = for alpha <- [0, 255, 1, 127, 128, 254], into: <<>>, do: <<1, 127, 128, alpha>>

    pipeline =
      start_pipeline(
        [frame(0, :binary.copy(<<1, 127, 128, 255>>, 6)), frame(100_000_000, pixels)],
        format
      )

    assert_sink_stream_format(pipeline, :sink, %GIF{width: 6, height: 1})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0, payload: first})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 100_000_000, payload: second})
    assert_end_of_stream(pipeline, :sink)
    assert %{width: 6, height: 1, images: 2, delays: [10, 10]} = GIFBlocks.parse(first <> second)
  end

  test "pipeline encodes RGBA animation with background disposal" do
    format = %{@format | width: 2, height: 1, pixel_format: :RGBA}

    frames = [
      frame(0, <<255, 0, 0, 255, 0, 0, 0, 0>>),
      frame(1_000_000_000, <<0, 255, 0, 0, 0, 0, 0, 0>>),
      frame(2_000_000_000, <<0, 0, 255, 255, 0, 0, 0, 0>>)
    ]

    pipeline = start_pipeline(frames, format, %Encoder{disposal: :background})

    assert_sink_stream_format(pipeline, :sink, %GIF{width: 2, height: 1})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0, payload: first})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_000_000_000, payload: second})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 2_000_000_000, payload: third})
    assert_end_of_stream(pipeline, :sink)

    assert %{width: 2, height: 1, images: 3, delays: [100, 100, 100]} =
             GIFBlocks.parse(first <> second <> third)
  end

  test "pipeline encodes 256 opaque RGBA colors with default and keep disposal" do
    format = %{@format | width: 256, height: 1, pixel_format: :RGBA}
    pixels = for gray <- 0..255, into: <<>>, do: <<gray, gray, gray, 255>>

    for encoder <- [%Encoder{}, %Encoder{disposal: :keep}] do
      pipeline = start_pipeline([frame(0, pixels)], format, encoder)

      assert_sink_stream_format(pipeline, :sink, %GIF{width: 256, height: 1})
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0, payload: gif})
      assert_end_of_stream(pipeline, :sink)
      assert %{width: 256, height: 1, images: 1, delays: [10]} = GIFBlocks.parse(gif)
    end
  end

  for {width, height} <- [{1, 1}, {65_535, 1}, {1, 65_535}] do
    test "pipeline encodes valid GIF boundary dimensions #{width}x#{height}" do
      width = unquote(width)
      height = unquote(height)
      format = %{@format | width: width, height: height}
      payload = :binary.copy(<<255, 0, 0>>, width * height)
      pipeline = start_pipeline([frame(0, payload)], format)

      assert_sink_stream_format(pipeline, :sink, %GIF{width: ^width, height: ^height})
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: gif})
      assert_end_of_stream(pipeline, :sink)
      assert %{width: ^width, height: ^height, images: 1, delays: [10]} = GIFBlocks.parse(gif)
    end
  end

  test "empty input ends without GIF bytes" do
    pipeline = start_pipeline([])

    assert_sink_stream_format(pipeline, :sink, %GIF{width: 16, height: 8})
    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, %Buffer{}, 0)
  end

  test "final frame uses the previous interval when no duration is supplied" do
    pipeline = start_pipeline([frame(0), frame(70_000_000)])

    assert_sink_buffer(pipeline, :sink, %Buffer{payload: first})
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: second})
    assert_end_of_stream(pipeline, :sink)
    assert %{images: 2, delays: [7, 7]} = GIFBlocks.parse(first <> second)
  end

  test "integer PTS beyond 64 bits retain frame timing and output timestamps" do
    for pts <- [-Integer.pow(2, 100), Integer.pow(2, 100)] do
      pipeline = start_pipeline([frame(pts), frame(pts + 40_000_000)])

      assert_sink_buffer(pipeline, :sink, %Buffer{pts: ^pts, payload: first})
      second_pts = pts + 40_000_000
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: ^second_pts, payload: second})
      assert_end_of_stream(pipeline, :sink)
      assert %{images: 2, delays: [4, 4]} = GIFBlocks.parse(first <> second)
    end
  end

  test "last-frame duration can reach the maximum GIF delay" do
    pipeline =
      start_pipeline([frame(0)], @format, %Encoder{last_frame_duration: 655_350_000_000})

    assert_sink_buffer(pipeline, :sink, %Buffer{payload: gif})
    assert_end_of_stream(pipeline, :sink)
    assert %{images: 1, delays: [65_535]} = GIFBlocks.parse(gif)
  end
end
