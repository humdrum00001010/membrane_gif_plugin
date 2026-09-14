defmodule Membrane.GIF.Encoder do
  @moduledoc """
  Membrane filter that encodes aligned raw video frames into an animated GIF
  byte stream.

  The filter accepts RGB and RGBA frames. RGBA alpha maps to GIF's 1-bit
  transparency mask: pixels with zero alpha are transparent, any other alpha
  value is opaque. RGBA buffers are independent frames: transparent pixels do
  not retain colors from earlier frames. Each RGBA frame reserves one palette
  index for transparency, leaving up to 255 opaque colors. Other pixel formats
  can be converted beforehand, e.g. with
  [membrane_ffmpeg_swscale_plugin](
  https://hexdocs.pm/membrane_ffmpeg_swscale_plugin/readme.html).

  Input buffers must carry integer PTS timestamps in nanoseconds, increasing
  strictly; declare `framerate: nil` in the stream format. Each frame's delay
  is the PTS difference to its successor, rounded to GIF centiseconds. The
  final delay uses `last_frame_duration`, the previous interval, or 100 ms.

  The output stream format is `Membrane.GIF`, which describes the GIF's
  dimensions. Concatenating all output buffer payloads produces one GIF file;
  individual buffers are not standalone images.
  """
  use Membrane.Filter

  import Membrane.Time, only: [is_time: 1]

  alias Membrane.Buffer
  alias Membrane.GIF
  alias Membrane.GIF.Encoder.Native
  alias Membrane.RawVideo

  # GIF dimensions and delays use unsigned 16-bit fields; repeat counts use the same width.
  @max_gif_value Integer.pow(2, 16) - 1

  def_input_pad :input,
    flow_control: :auto,
    accepted_format:
      %RawVideo{aligned: true, framerate: nil, pixel_format: format}
      when format in [:RGB, :RGBA]

  def_output_pad :output, flow_control: :auto, accepted_format: GIF

  def_options loop: [
                spec: non_neg_integer() | nil,
                default: nil,
                description: "GIF repeat count; 0 loops forever, nil omits the loop extension."
              ],
              last_frame_duration: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description: "Optional final-frame duration in nanoseconds."
              ]

  @impl true
  def handle_init(_ctx, %__MODULE__{} = options) do
    if not (is_nil(options.loop) or
              (is_integer(options.loop) and options.loop in 0..@max_gif_value)) do
      raise "loop must be nil or an integer in 0..#{@max_gif_value}"
    end

    if not (is_nil(options.last_frame_duration) or
              (is_time(options.last_frame_duration) and options.last_frame_duration > 0)) do
      raise "last_frame_duration must be nil or a positive time"
    end

    {[],
     %{
       loop: options.loop,
       last_frame_duration: options.last_frame_duration,
       format: nil,
       frame_size: nil,
       encoder_ref: nil,
       pending: nil,
       origin: nil,
       last_interval: nil
     }}
  end

  @impl true
  def handle_stream_format(:input, %RawVideo{} = format, _ctx, state) do
    if not is_nil(state.format) and state.format != format do
      raise "GIF encoder does not support stream-format changes"
    end

    if not (is_integer(format.width) and format.width in 1..@max_gif_value and
              is_integer(format.height) and format.height in 1..@max_gif_value) do
      raise "GIF dimensions must be in 1..#{@max_gif_value}"
    end

    if state.format == format do
      {[], state}
    else
      {:ok, frame_size} = RawVideo.frame_size(format)

      create_options =
        format
        |> Map.take([:width, :height, :pixel_format])
        |> Map.put(:loop, state.loop)

      {:ok, encoder_ref} = Native.create(create_options)
      output = %GIF{width: format.width, height: format.height}

      {[stream_format: {:output, output}],
       %{state | format: format, frame_size: frame_size, encoder_ref: encoder_ref}}
    end
  end

  @impl true
  def handle_buffer(:input, %Buffer{pts: pts, payload: pixels} = buffer, _ctx, state) do
    if not is_time(pts) do
      raise "GIF input requires integer PTS timestamps on every frame"
    end

    if not is_nil(state.pending) and pts <= state.pending.pts do
      raise "GIF timestamps must increase strictly"
    end

    if not is_binary(pixels) or byte_size(pixels) != state.frame_size do
      raise "invalid_frame_size"
    end

    if is_nil(state.pending) do
      {[buffer: {:output, []}], %{state | pending: buffer, origin: pts}}
    else
      output = encode_pending(state, pts)

      {[buffer: {:output, [output]}],
       %{state | pending: buffer, last_interval: pts - state.pending.pts}}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{encoder_ref: nil} = state),
    do: {[end_of_stream: :output], state}

  def handle_end_of_stream(:input, _ctx, %{pending: nil} = state) do
    {:ok, _trailer} = Native.finish(state.encoder_ref)

    {[buffer: {:output, []}, end_of_stream: :output],
     %{state | encoder_ref: nil, pending: nil, origin: nil, last_interval: nil}}
  end

  def handle_end_of_stream(:input, _ctx, %{pending: %Buffer{pts: pts}} = state) do
    duration = state.last_frame_duration || state.last_interval || 100_000_000
    frame = encode_pending(state, pts + duration)
    {:ok, trailer} = Native.finish(state.encoder_ref)
    output = %{frame | payload: frame.payload <> trailer}

    {[buffer: {:output, [output]}, end_of_stream: :output],
     %{state | encoder_ref: nil, pending: nil, origin: nil, last_interval: nil}}
  end

  defp encode_pending(
         %{encoder_ref: encoder_ref, pending: %Buffer{pts: pts, payload: pixels}, origin: origin},
         end_pts
       ) do
    # Round cumulative boundaries relative to the first PTS into GIF centiseconds.
    start = div(pts - origin + 5_000_000, 10_000_000)
    stop = div(end_pts - origin + 5_000_000, 10_000_000)
    delay_cs = stop - start

    if delay_cs not in 1..@max_gif_value do
      raise "GIF frame delay must round to 1..#{@max_gif_value} centiseconds"
    end

    {:ok, payload} = Native.encode(encoder_ref, pixels, delay_cs)
    %Buffer{pts: pts, payload: payload}
  end
end
