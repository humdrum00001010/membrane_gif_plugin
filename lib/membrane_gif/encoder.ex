defmodule Membrane.GIF.Encoder do
  @moduledoc """
  Encodes aligned raw video frames into one animated GIF byte stream.

  Uses FFmpeg's fixed RGB8 palette. Holds one encoded frame to derive its delay
  from the next frame's PTS. Input must either have strictly increasing integer
  nanosecond PTS on every buffer, or omit PTS on every buffer and declare a
  positive framerate. Timestamp origins may be arbitrary.

  Frame boundaries are rounded to centiseconds without accumulating per-frame
  rounding error. Delays outside 1..65535 centiseconds are rejected. The final
  delay uses `last_frame_duration`, the previous interval, the nominal frame
  duration, or 100 ms, in that order. Empty input emits no GIF bytes.

  Stream-format changes are unsupported. End of stream finishes the file;
  the native resource is released when the element's reference is collected.
  """
  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.GIF
  alias Membrane.RawVideo
  alias Membrane.GIF.Encoder.Native
  alias Membrane.GIF.Muxing

  def_input_pad :input,
    flow_control: :auto,
    accepted_format:
      %RawVideo{aligned: true, pixel_format: format}
      when format in [:I420, :I422, :I444, :RGB, :BGR, :RGBA, :BGRA, :NV12, :NV21, :YUY2]

  def_output_pad :output, flow_control: :auto, accepted_format: GIF

  def_options loop: [
                spec: non_neg_integer() | nil,
                default: 0,
                description: "GIF repeat count; 0 loops forever, nil omits the loop extension."
              ],
              last_frame_duration: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description: "Optional final-frame duration in nanoseconds."
              ]

  @impl true
  def handle_init(_ctx, opts) do
    mux = Muxing.new(opts.loop, opts.last_frame_duration, nil)
    {[], %{native: nil, format: nil, mux: mux, index: 0, timing: nil}}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, %{format: format} = state), do: {[], state}

  def handle_stream_format(:input, %RawVideo{} = format, _ctx, %{format: nil} = state) do
    {:ok, _size} = RawVideo.frame_size(format)

    nominal =
      case format.framerate do
        nil -> nil
        {num, den} when num > 0 and den > 0 -> div(den * 1_000_000_000, num)
        _other -> raise ArgumentError, "GIF requires a positive framerate or nil"
      end

    {:ok, native} = Native.create(format.width, format.height, format.pixel_format)
    output = %GIF{width: format.width, height: format.height}

    {[stream_format: {:output, output}],
     %{state | native: native, format: format, mux: %{state.mux | nominal_duration: nominal}}}
  end

  def handle_stream_format(:input, _format, _ctx, _state),
    do: raise(ArgumentError, "GIF encoder does not support stream-format changes")

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    timing = if is_nil(buffer.pts), do: :framerate, else: :pts

    if state.timing != nil and state.timing != timing,
      do: raise(ArgumentError, "GIF input cannot mix timestamped and untimestamped frames")

    pts =
      case {buffer.pts, state.format.framerate} do
        {pts, _rate} when is_integer(pts) ->
          pts

        {nil, {num, den}} when num > 0 and den > 0 ->
          div(state.index * den * 1_000_000_000, num)

        _other ->
          raise ArgumentError, "GIF input requires integer PTS or a declared framerate"
      end

    # The selected FFmpeg GIF codec produces one packet per input frame with a fixed delay.
    {:ok, [packet]} = Native.encode(buffer.payload, state.native)
    {buffers, mux} = Muxing.push(%Buffer{payload: packet, pts: pts}, state.mux)
    {[buffer: {:output, buffers}], %{state | mux: mux, index: state.index + 1, timing: timing}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{native: nil} = state),
    do: {[end_of_stream: :output], state}

  def handle_end_of_stream(:input, _ctx, state) do
    {:ok, []} = Native.flush(state.native)
    {buffers, mux} = Muxing.finish(state.mux)
    {[buffer: {:output, buffers}, end_of_stream: :output], %{state | mux: mux, native: nil}}
  end
end
