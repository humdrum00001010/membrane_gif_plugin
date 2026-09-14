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
  @format %RawVideo{width: 16, height: 8, pixel_format: :RGB, aligned: true, framerate: {25, 1}}

  defp start_encoder(rate \\ {25, 1}, opts \\ %Encoder{}) do
    {[], state} = Encoder.handle_init(%{}, opts)

    {_actions, state} =
      Encoder.handle_stream_format(:input, %{@format | framerate: rate}, %{}, state)

    state
  end

  defp frame(pts), do: %Buffer{payload: @frame, pts: pts}

  test "initial state groups timing separately from encoder configuration" do
    opts = %Encoder{}

    assert Encoder.handle_init(%{}, opts) ==
             {[],
              %{
                encoder_ref: nil,
                format: nil,
                frame_size: nil,
                options: opts,
                timing: %{
                  pending: nil,
                  origin: nil,
                  last_interval: nil,
                  timestamped: nil,
                  index: 0
                }
              }}
  end

  for loop <- [nil, 0, 65_535] do
    test "accepts loop #{inspect(loop)}" do
      opts = %Encoder{loop: unquote(loop)}
      assert {[], %{options: ^opts}} = Encoder.handle_init(%{}, opts)
    end
  end

  for loop <- [-1, 65_536, 1.5] do
    test "rejects loop #{inspect(loop)}" do
      assert_raise ArgumentError, "loop must be nil or an integer in 0..65535", fn ->
        Encoder.handle_init(%{}, %Encoder{loop: unquote(loop)})
      end
    end
  end

  for duration <- [0, -1, 1.5] do
    test "rejects last_frame_duration #{inspect(duration)}" do
      assert_raise ArgumentError, "last_frame_duration must be a positive duration or nil", fn ->
        Encoder.handle_init(%{}, %Encoder{last_frame_duration: unquote(duration)})
      end
    end
  end

  for rate <- [{0, 1}, {25, 0}, {-1, 1}, :unknown, {1.5, 1}] do
    test "rejects framerate #{inspect(rate)}" do
      assert_raise ArgumentError, "GIF requires a positive framerate or nil", fn ->
        start_encoder(unquote(Macro.escape(rate)))
      end
    end
  end

  test "rejects a change in dimensions after accepting the initial format" do
    state = start_encoder()

    assert_raise ArgumentError, "GIF encoder does not support stream-format changes", fn ->
      Encoder.handle_stream_format(:input, %{@format | width: 32}, %{}, state)
    end

    assert {[], ^state} = Encoder.handle_stream_format(:input, @format, %{}, state)
  end

  for {width, height} <- [
        {0, 8},
        {16, 0},
        {-1, 8},
        {65_536, 8},
        {16, 65_536},
        {0.5, 8},
        {16, nil}
      ] do
    test "rejects dimensions #{inspect(width)}x#{inspect(height)} before native initialization" do
      {[], state} = Encoder.handle_init(%{}, %Encoder{})
      format = %{@format | width: unquote(width), height: unquote(height)}

      assert_raise ArgumentError, "GIF dimensions must be in 1..65535", fn ->
        Encoder.handle_stream_format(:input, format, %{}, state)
      end
    end
  end

  for {formats, width, height} <- [
        {[
           :I420,
           :I422,
           :NV12,
           :NV21,
           :YUY2,
           :YV12,
           :I420_10LE,
           :I420_10BE,
           :I422_10LE,
           :I422_10BE
         ], 3, 2},
        {[:I420, :NV12, :NV21, :YV12, :I420_10LE, :I420_10BE], 4, 3}
      ],
      format <- formats do
    test "rejects #{width}x#{height} #{format} subsampling before native initialization" do
      {[], state} = Encoder.handle_init(%{}, %Encoder{})

      format = %{
        @format
        | width: unquote(width),
          height: unquote(height),
          pixel_format: unquote(format)
      }

      assert_raise ArgumentError, "Invalid dimensions for the input pixel format", fn ->
        Encoder.handle_stream_format(:input, format, %{}, state)
      end
    end
  end

  for {first, second} <- [{nil, 40_000_000}, {nil, Integer.pow(2, 100)}, {0, nil}] do
    test "rejects switching PTS mode from #{inspect(first)} to #{inspect(second)}" do
      {_actions, state} =
        Encoder.handle_buffer(:input, frame(unquote(first)), %{}, start_encoder())

      assert_raise ArgumentError,
                   "GIF input cannot mix timestamped and untimestamped frames",
                   fn ->
                     Encoder.handle_buffer(:input, frame(unquote(second)), %{}, state)
                   end
    end
  end

  for pts <- [nil, 0.5, :unknown] do
    test "rejects #{inspect(pts)} PTS when no framerate is declared" do
      state = start_encoder(nil)

      assert_raise ArgumentError, "GIF input requires integer PTS or a declared framerate", fn ->
        Encoder.handle_buffer(:input, frame(unquote(pts)), %{}, state)
      end
    end
  end

  test "large generated timestamps are limited by GIF frame delays" do
    state = start_encoder({1, Integer.pow(2, 63)})
    {_actions, state} = Encoder.handle_buffer(:input, frame(nil), %{}, state)

    assert_raise ArgumentError, "GIF frame delay must round to 1..65535 centiseconds", fn ->
      Encoder.handle_buffer(:input, frame(nil), %{}, state)
    end
  end

  test "sub-nanosecond frame periods reject repeated timestamps and zero final delay" do
    state = start_encoder({2_000_000_000, 1})
    {_actions, state} = Encoder.handle_buffer(:input, frame(nil), %{}, state)

    assert_raise ArgumentError, "GIF timestamps must increase strictly", fn ->
      Encoder.handle_buffer(:input, frame(nil), %{}, state)
    end

    assert_raise ArgumentError, "GIF frame delay must round to 1..65535 centiseconds", fn ->
      Encoder.handle_end_of_stream(:input, %{}, state)
    end
  end

  test "invalid payloads are rejected before retaining a frame or emitting the previous one" do
    state = start_encoder()

    for bad_size <- [0, byte_size(@frame) - 1, byte_size(@frame) + 1] do
      buffer = %Buffer{payload: :binary.copy(<<128>>, bad_size), pts: 0}

      assert_raise ArgumentError, "invalid_frame_size", fn ->
        Encoder.handle_buffer(:input, buffer, %{}, state)
      end
    end

    {_actions, state} = Encoder.handle_buffer(:input, frame(0), %{}, state)

    assert_raise ArgumentError, "invalid_frame_size", fn ->
      Encoder.handle_buffer(:input, %Buffer{payload: <<>>, pts: 40_000_000}, %{}, state)
    end

    {[buffer: {:output, [first]}], state} =
      Encoder.handle_buffer(:input, frame(40_000_000), %{}, state)

    {[buffer: {:output, [last]}, end_of_stream: :output], _state} =
      Encoder.handle_end_of_stream(:input, %{}, state)

    assert %{images: 2, delays: [4, 4]} = GIFBlocks.parse(first.payload <> last.payload)
  end

  for {format, size} <- [
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
      ],
      {kind, bad_size} <- [empty: 0, truncated: size - 1, oversized: size + 1] do
    test "#{format}: rejects #{kind} payload at the element input" do
      {[], state} = Encoder.handle_init(%{}, %Encoder{})

      {_actions, state} =
        Encoder.handle_stream_format(
          :input,
          %{@format | pixel_format: unquote(format)},
          %{},
          state
        )

      buffer = %Buffer{payload: :binary.copy(<<128>>, unquote(bad_size)), pts: 0}

      assert_raise ArgumentError, "invalid_frame_size", fn ->
        Encoder.handle_buffer(:input, buffer, %{}, state)
      end
    end
  end

  for second_pts <- [100_000_000, 90_000_000] do
    test "rejects non-increasing timestamp #{second_pts}" do
      {_actions, state} = Encoder.handle_buffer(:input, frame(100_000_000), %{}, start_encoder())

      assert_raise ArgumentError, "GIF timestamps must increase strictly", fn ->
        Encoder.handle_buffer(:input, frame(unquote(second_pts)), %{}, state)
      end
    end
  end

  for duration <- [1_000_000, 655_360_000_000] do
    test "rejects unrepresentable inter-frame duration #{duration}" do
      {_actions, state} = Encoder.handle_buffer(:input, frame(0), %{}, start_encoder())

      assert_raise ArgumentError, "GIF frame delay must round to 1..65535 centiseconds", fn ->
        Encoder.handle_buffer(:input, frame(unquote(duration)), %{}, state)
      end
    end

    test "rejects unrepresentable final duration #{duration} at EOS" do
      state = start_encoder(nil, %Encoder{last_frame_duration: unquote(duration)})
      {_actions, state} = Encoder.handle_buffer(:input, frame(0), %{}, state)

      assert_raise ArgumentError, "GIF frame delay must round to 1..65535 centiseconds", fn ->
        Encoder.handle_end_of_stream(:input, %{}, state)
      end
    end
  end

  test "pipeline emits timed GIF chunks with a loop extension and trailer" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(:source, %Testing.Source{
            stream_format: @format,
            output: [frame(1_000_000_000), frame(1_070_000_000), frame(1_160_000_000)]
          })
          |> child(:encoder, %Encoder{loop: 2, last_frame_duration: 50_000_000})
          |> child(:sink, Testing.Sink)
      )

    assert_sink_stream_format(pipeline, :sink, %GIF{width: 16, height: 8})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_000_000_000, payload: first})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_070_000_000, payload: second})
    assert_sink_buffer(pipeline, :sink, %Buffer{pts: 1_160_000_000, payload: third})
    assert_end_of_stream(pipeline, :sink)

    assert %{width: 16, height: 8, images: 3, loop: 2, delays: [7, 9, 5]} =
             GIFBlocks.parse(first <> second <> third)

    encoder = Testing.Pipeline.get_child_pid!(pipeline, :encoder)

    assert %{internal_state: %{encoder_ref: nil, timing: %{pending: nil}}} =
             :sys.get_state(encoder)
  end

  test "framerate-only input rounds cumulative boundaries and omits optional looping" do
    state = start_encoder({30, 1}, %Encoder{loop: nil})
    {[buffer: {:output, []}], state} = Encoder.handle_buffer(:input, frame(nil), %{}, state)
    {[buffer: {:output, [first]}], state} = Encoder.handle_buffer(:input, frame(nil), %{}, state)
    {[buffer: {:output, [second]}], state} = Encoder.handle_buffer(:input, frame(nil), %{}, state)

    {[buffer: {:output, [last]}, end_of_stream: :output], _state} =
      Encoder.handle_end_of_stream(:input, %{}, state)

    assert first.pts == 0
    assert second.pts == 33_333_333
    assert last.pts == 66_666_666

    assert %{images: 3, delays: [3, 4, 3], loop: nil} =
             GIFBlocks.parse(first.payload <> second.payload <> last.payload)
  end

  for {format, size} <- [
        YV12: 192,
        AYUV: 512,
        I420_10LE: 384,
        I420_10BE: 384,
        I422_10LE: 512,
        I422_10BE: 512,
        I444_10LE: 768,
        I444_10BE: 768
      ] do
    test "pipeline encodes #{format} input and finalizes its GIF" do
      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec:
            child(:source, %Testing.Source{
              stream_format: %{@format | pixel_format: unquote(format)},
              output: [%Buffer{payload: :binary.copy(<<1>>, unquote(size)), pts: 0}]
            })
            |> child(:encoder, Encoder)
            |> child(:sink, Testing.Sink)
        )

      assert_sink_stream_format(pipeline, :sink, %GIF{width: 16, height: 8})
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: 0, payload: gif})
      assert_end_of_stream(pipeline, :sink)
      assert %{width: 16, height: 8, images: 1, delays: [4]} = GIFBlocks.parse(gif)
    end
  end

  for {width, height} <- [{1, 1}, {Integer.pow(2, 16) - 1, 1}, {1, Integer.pow(2, 16) - 1}] do
    test "pipeline encodes valid GIF boundary dimensions #{width}x#{height}" do
      width = unquote(width)
      height = unquote(height)

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec:
            child(:source, %Testing.Source{
              stream_format: %{@format | width: width, height: height},
              output: [%Buffer{payload: :binary.copy(<<255, 0, 0>>, width * height), pts: 0}]
            })
            |> child(:encoder, Encoder)
            |> child(:sink, Testing.Sink)
        )

      assert_sink_buffer(pipeline, :sink, %Buffer{payload: gif})
      assert_end_of_stream(pipeline, :sink)
      assert %{width: ^width, height: ^height, images: 1, delays: [4]} = GIFBlocks.parse(gif)
    end
  end

  for {rate, delay} <- [{{25, 1}, 4}, {nil, 10}] do
    test "single timestamped frame uses fallback delay #{delay}" do
      state = start_encoder(unquote(Macro.escape(rate)), %Encoder{loop: nil})
      {_actions, state} = Encoder.handle_buffer(:input, frame(-1_000_000_000), %{}, state)

      {[buffer: {:output, [buffer]}, end_of_stream: :output], _state} =
        Encoder.handle_end_of_stream(:input, %{}, state)

      assert %{images: 1, delays: [unquote(delay)], loop: nil} = GIFBlocks.parse(buffer.payload)
    end
  end

  test "empty input emits EOS without GIF bytes" do
    assert {[buffer: {:output, []}, end_of_stream: :output], _state} =
             Encoder.handle_end_of_stream(:input, %{}, start_encoder())

    {[], state} = Encoder.handle_init(%{}, %Encoder{})
    assert {[end_of_stream: :output], _state} = Encoder.handle_end_of_stream(:input, %{}, state)
  end

  test "final delay uses the previous interval before the declared framerate" do
    state = start_encoder({25, 1})
    {_actions, state} = Encoder.handle_buffer(:input, frame(0), %{}, state)

    {[buffer: {:output, [first]}], state} =
      Encoder.handle_buffer(:input, frame(70_000_000), %{}, state)

    {[buffer: {:output, [last]}, end_of_stream: :output], _state} =
      Encoder.handle_end_of_stream(:input, %{}, state)

    assert %{images: 2, delays: [7, 7]} = GIFBlocks.parse(first.payload <> last.payload)
  end

  test "integer timestamps beyond 64 bits preserve frame timing and output PTS" do
    for pts <- [-Integer.pow(2, 100), Integer.pow(2, 100)] do
      {_actions, state} = Encoder.handle_buffer(:input, frame(pts), %{}, start_encoder(nil))

      {[buffer: {:output, [first]}], state} =
        Encoder.handle_buffer(:input, frame(pts + 40_000_000), %{}, state)

      {[buffer: {:output, [last]}, end_of_stream: :output], state} =
        Encoder.handle_end_of_stream(:input, %{}, state)

      assert first.pts == pts
      assert last.pts == pts + 40_000_000
      assert %{images: 2, delays: [4, 4]} = GIFBlocks.parse(first.payload <> last.payload)
      assert state.timing.pending == nil
    end
  end

  test "final duration can reach the maximum GIF delay" do
    state = start_encoder(nil, %Encoder{last_frame_duration: 655_350_000_000})
    {_actions, state} = Encoder.handle_buffer(:input, frame(0), %{}, state)

    {[buffer: {:output, [buffer]}, end_of_stream: :output], _state} =
      Encoder.handle_end_of_stream(:input, %{}, state)

    assert %{images: 1, delays: [65_535]} = GIFBlocks.parse(buffer.payload)
  end
end
