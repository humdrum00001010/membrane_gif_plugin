defmodule Membrane.GIF.Encoder.FailureTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec

  alias Membrane.Buffer
  alias Membrane.GIF.Encoder
  alias Membrane.RawVideo
  alias Membrane.Testing

  @frame :binary.copy(<<128>>, 16 * 8 * 3)
  @format %RawVideo{width: 16, height: 8, pixel_format: :RGB, aligned: true, framerate: {25, 1}}

  for {option, value, message} <- [
        {:loop, -1, "loop must be nil or an integer in 0..65535"},
        {:last_frame_duration, 0, "last_frame_duration must be a positive duration or nil"}
      ] do
    test "pipeline rejects #{option}: #{inspect(value)} during element initialization" do
      encoder = struct!(Encoder, [{unquote(option), unquote(value)}])

      assert {%Membrane.ParentError{message: message}, _stacktrace} =
               pipeline_failure(%Testing.Source{stream_format: @format, output: []}, encoder)

      assert message =~ "Error starting child :encoder"
      assert message =~ inspect(%ArgumentError{message: unquote(message)})
      assert message =~ "Membrane.GIF.Encoder, :handle_init"
    end
  end

  test "upstream declares a zero framerate" do
    source = %Testing.Source{stream_format: %{@format | framerate: {0, 1}}, output: []}

    assert_encoder_error(
      source,
      "GIF requires a positive framerate or nil",
      :handle_stream_format
    )
  end

  test "upstream declares dimensions exceeding GIF capacity" do
    source = %Testing.Source{stream_format: %{@format | width: 65_536}, output: []}

    assert_encoder_error(source, "GIF dimensions must be in 1..65535", :create_encoder)
  end

  test "upstream declares invalid subsampled dimensions" do
    source = %Testing.Source{
      stream_format: %{@format | width: 3, height: 2, pixel_format: :I420},
      output: []
    }

    assert_encoder_error(source, "Invalid dimensions for the input pixel format", :create_encoder)
  end

  test "upstream changes resolution after sending a frame" do
    actions = [
      buffer: {:output, [%Buffer{payload: @frame, pts: 0}]},
      stream_format: {:output, %{@format | width: 32}},
      end_of_stream: :output
    ]

    source = %Testing.Source{
      stream_format: @format,
      output: {actions, fn actions, _demand -> {actions, []} end}
    }

    assert_encoder_error(
      source,
      "GIF encoder does not support stream-format changes",
      :handle_stream_format
    )
  end

  for {first, second} <- [{nil, 40_000_000}, {0, nil}] do
    test "upstream switches PTS mode from #{inspect(first)} to #{inspect(second)}" do
      source = %Testing.Source{
        stream_format: @format,
        output: [
          %Buffer{payload: @frame, pts: unquote(first)},
          %Buffer{payload: @frame, pts: unquote(second)}
        ]
      }

      assert_encoder_error(
        source,
        "GIF input cannot mix timestamped and untimestamped frames",
        :handle_buffer
      )
    end
  end

  test "upstream supplies neither PTS nor framerate" do
    source = %Testing.Source{
      stream_format: %{@format | framerate: nil},
      output: [%Buffer{payload: @frame}]
    }

    assert_encoder_error(
      source,
      "GIF input requires integer PTS or a declared framerate",
      :handle_buffer
    )
  end

  test "upstream repeats a timestamp" do
    source = %Testing.Source{
      stream_format: @format,
      output: [
        %Buffer{payload: @frame, pts: 100_000_000},
        %Buffer{payload: @frame, pts: 100_000_000}
      ]
    }

    assert_encoder_error(source, "GIF timestamps must increase strictly", :queue_frame)
  end

  test "upstream supplies a truncated frame" do
    source = %Testing.Source{
      stream_format: @format,
      output: [%Buffer{payload: binary_part(@frame, 0, byte_size(@frame) - 1), pts: 0}]
    }

    assert_encoder_error(source, "invalid_frame_size", :queue_frame)
  end

  test "upstream frame interval rounds to zero GIF delay" do
    source = %Testing.Source{
      stream_format: @format,
      output: [%Buffer{payload: @frame, pts: 0}, %Buffer{payload: @frame, pts: 1_000_000}]
    }

    assert_encoder_error(
      source,
      "GIF frame delay must round to 1..65535 centiseconds",
      :encode_pending
    )
  end

  test "upstream EOS exposes an excessive final duration" do
    source = %Testing.Source{stream_format: @format, output: [%Buffer{payload: @frame, pts: 0}]}

    assert_encoder_error(
      source,
      "GIF frame delay must round to 1..65535 centiseconds",
      :encode_pending,
      %Encoder{last_frame_duration: 655_360_000_000}
    )
  end

  defp assert_encoder_error(source, message, function, encoder \\ %Encoder{}) do
    assert {:membrane_child_crash, :encoder,
            {%ArgumentError{message: ^message},
             [{Encoder, actual_function, _arity, _location} | _rest]}} =
             pipeline_failure(source, encoder)

    # Some Elixir versions compile `with` branches as anonymous functions.
    assert actual_function == function or
             String.starts_with?(Atom.to_string(actual_function), "-#{function}/")
  end

  defp pipeline_failure(source, encoder) do
    {:ok, supervisor, pipeline} =
      {Testing.Pipeline, test_process: self()}
      |> Supervisor.child_spec(restart: :temporary)
      |> start_supervised()

    # Monitor before adding children so initialization failures are observed too.
    pipeline_monitor = Process.monitor(pipeline)
    supervisor_monitor = Process.monitor(supervisor)

    Testing.Pipeline.execute_actions(pipeline,
      spec:
        child(:source, source)
        |> child(:encoder, encoder)
        |> child(:sink, Testing.Sink)
    )

    assert_receive {:DOWN, ^pipeline_monitor, :process, ^pipeline, reason}, 5_000
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, _reason}, 5_000
    reason
  end
end
