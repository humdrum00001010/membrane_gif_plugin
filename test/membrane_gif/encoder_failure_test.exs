defmodule Membrane.GIF.Encoder.FailureTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec

  alias Membrane.Buffer
  alias Membrane.GIF.Encoder
  alias Membrane.RawVideo
  alias Membrane.Testing

  @frame :binary.copy(<<128>>, 16 * 8 * 3)
  @format %RawVideo{width: 16, height: 8, pixel_format: :RGB, aligned: true, framerate: nil}

  for {option, value} <- [loop: -1, loop: 65_536, last_frame_duration: 0, disposal: :invalid] do
    test "rejects encoder option #{option}: #{inspect(value)}" do
      encoder = struct!(Encoder, [{unquote(option), unquote(value)}])
      source = %Testing.Source{stream_format: @format, output: []}
      assert_startup_error(source, encoder)
    end
  end

  for {width, height} <- [{0, 8}, {65_536, 8}, {16, nil}] do
    test "rejects input dimensions #{inspect(width)}x#{inspect(height)}" do
      source = %Testing.Source{
        stream_format: %{@format | width: unquote(width), height: unquote(height)},
        output: []
      }

      assert_encoder_error(source)
    end
  end

  test "Membrane rejects input formats outside the pad contract" do
    for format <- [
          %{@format | aligned: false},
          %{@format | framerate: {30, 1}},
          %{@format | pixel_format: :GRAY16}
        ] do
      source = %Testing.Source{stream_format: format, output: []}

      assert {:membrane_child_crash, :encoder, {%Membrane.StreamFormatError{}, _stacktrace}} =
               pipeline_failure(source, %Encoder{})
    end
  end

  test "rejects a stream-format change after receiving a frame" do
    actions = [
      buffer: {:output, [%Buffer{payload: @frame, pts: 0}]},
      stream_format: {:output, %{@format | width: 32}},
      end_of_stream: :output
    ]

    source = %Testing.Source{
      stream_format: @format,
      output: {actions, fn actions, _demand -> {actions, []} end}
    }

    assert_encoder_error(source)
  end

  for pts <- [nil, 0.5] do
    test "rejects input frame without integer PTS #{inspect(pts)}" do
      source = %Testing.Source{
        stream_format: @format,
        output: [%Buffer{payload: @frame, pts: unquote(pts)}]
      }

      assert_encoder_error(source)
    end
  end

  for second_pts <- [100_000_000, 90_000_000] do
    test "rejects non-increasing PTS #{second_pts}" do
      source = %Testing.Source{
        stream_format: @format,
        output: [
          %Buffer{payload: @frame, pts: 100_000_000},
          %Buffer{payload: @frame, pts: unquote(second_pts)}
        ]
      }

      assert_encoder_error(source)
    end
  end

  test "rejects a wrong-sized frame" do
    source = %Testing.Source{
      stream_format: @format,
      output: [%Buffer{payload: binary_part(@frame, 0, byte_size(@frame) - 1), pts: 0}]
    }

    assert_encoder_error(source)
  end

  for second_pts <- [1_000_000, 655_360_000_000] do
    test "rejects unrepresentable inter-frame delay #{second_pts}" do
      source = %Testing.Source{
        stream_format: @format,
        output: [
          %Buffer{payload: @frame, pts: 0},
          %Buffer{payload: @frame, pts: unquote(second_pts)}
        ]
      }

      assert_encoder_error(source)
    end
  end

  test "rejects excessive final-frame duration at EOS" do
    source = %Testing.Source{stream_format: @format, output: [%Buffer{payload: @frame, pts: 0}]}

    assert_encoder_error(source, %Encoder{last_frame_duration: 655_360_000_000})
  end

  defp assert_encoder_error(source, encoder \\ %Encoder{}) do
    assert {:membrane_child_crash, :encoder, {%RuntimeError{}, _stacktrace}} =
             pipeline_failure(source, encoder)
  end

  defp assert_startup_error(source, encoder) do
    assert {%Membrane.ParentError{}, _stacktrace} = pipeline_failure(source, encoder)
  end

  defp pipeline_failure(source, encoder) do
    {:ok, supervisor, pipeline} =
      {Testing.Pipeline, test_process: self()}
      |> Supervisor.child_spec(restart: :temporary)
      |> start_supervised()

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
