defmodule Membrane.GIF.EncoderTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.Buffer
  alias Membrane.GIF
  alias Membrane.RawVideo
  alias Membrane.Testing
  alias Membrane.GIF.Encoder

  @frame :binary.copy(<<128>>, 16 * 8 * 3)
  @format %RawVideo{width: 16, height: 8, pixel_format: :RGB, aligned: true, framerate: {25, 1}}

  defp start_encoder(rate \\ {25, 1}, opts \\ %Encoder{}) do
    {[], state} = Encoder.handle_init(%{}, opts)

    {_actions, state} =
      Encoder.handle_stream_format(:input, %{@format | framerate: rate}, %{}, state)

    state
  end

  defp frame(pts), do: %Buffer{payload: @frame, pts: pts}

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

  for rate <- [{0, 1}, {25, 0}, {-1, 1}] do
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

  for {first, second} <- [{nil, 40_000_000}, {0, nil}] do
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

  for pts <- [nil, 0.5] do
    test "rejects #{inspect(pts)} PTS when no framerate is declared" do
      state = start_encoder(nil)

      assert_raise ArgumentError, "GIF input requires integer PTS or a declared framerate", fn ->
        Encoder.handle_buffer(:input, frame(unquote(pts)), %{}, state)
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

    # Our RGB8 encoder writes the 13-byte header and a 256-entry global palette.
    assert <<"GIF89a", 16::16-little, 8::16-little, _palette::binary-size(771), 0x21, 0xFF, 11,
             "NETSCAPE2.0", 3, 1, 2::16-little, 0, 0x21, 0xF9, 4, _flags, 7::16-little,
             _frame::binary>> = first

    assert <<0x21, 0xF9, 4, _flags, 9::16-little, _frame::binary>> = second
    assert <<0x21, 0xF9, 4, _flags, 5::16-little, _frame::binary>> = third
    assert :binary.last(third) == 0x3B
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

    assert <<_header::binary-size(781), 0x21, 0xF9, 4, _flags, 3::16-little, _frame::binary>> =
             first.payload

    assert <<0x21, 0xF9, 4, _flags, 4::16-little, _frame::binary>> = second.payload
    assert <<0x21, 0xF9, 4, _flags, 3::16-little, _frame::binary>> = last.payload
    refute first.payload =~ "NETSCAPE2.0"
  end

  for {rate, delay} <- [{{25, 1}, 4}, {nil, 10}] do
    test "single timestamped frame uses fallback delay #{delay}" do
      state = start_encoder(unquote(Macro.escape(rate)), %Encoder{loop: nil})
      {_actions, state} = Encoder.handle_buffer(:input, frame(-1_000_000_000), %{}, state)

      {[buffer: {:output, [buffer]}, end_of_stream: :output], _state} =
        Encoder.handle_end_of_stream(:input, %{}, state)

      assert <<_header::binary-size(781), 0x21, 0xF9, 4, _flags, unquote(delay)::16-little,
               _frame::binary>> =
               buffer.payload

      assert :binary.last(buffer.payload) == 0x3B
    end
  end

  test "empty input emits EOS without GIF bytes" do
    assert {[buffer: {:output, []}, end_of_stream: :output], _state} =
             Encoder.handle_end_of_stream(:input, %{}, start_encoder())

    {[], state} = Encoder.handle_init(%{}, %Encoder{})
    assert {[end_of_stream: :output], _state} = Encoder.handle_end_of_stream(:input, %{}, state)
  end
end
