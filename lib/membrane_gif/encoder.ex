defmodule Membrane.GIF.Encoder do
  @moduledoc """
  It encodes aligned raw video frames into one animated GIF byte stream.
  """
  use Membrane.Filter

  import Membrane.Time, only: [is_time: 1]

  alias Membrane.Buffer
  alias Membrane.GIF
  alias Membrane.GIF.Encoder.Native
  alias Membrane.RawVideo

  # GIF dimensions and delays use unsigned 16-bit fields; repeat counts use the same width.
  # https://www.w3.org/Graphics/GIF/spec-gif89a.txt
  @max_gif_value Integer.pow(2, 16) - 1

  def_input_pad :input,
    flow_control: :auto,
    accepted_format:
      %RawVideo{aligned: true, pixel_format: format}
      when format in [
             :I420,
             :I422,
             :I444,
             :RGB,
             :BGR,
             :RGBA,
             :BGRA,
             :NV12,
             :NV21,
             :YUY2,
             :YV12,
             :AYUV,
             :I420_10LE,
             :I420_10BE,
             :I422_10LE,
             :I422_10BE,
             :I444_10LE,
             :I444_10BE
           ]

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
  def handle_init(_ctx, %{loop: loop, last_frame_duration: duration} = opts)
      when (is_nil(loop) or (is_integer(loop) and loop in 0..@max_gif_value)) and
             (is_nil(duration) or (is_time(duration) and duration > 0)) do
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

  def handle_init(_ctx, %{loop: loop})
      when is_nil(loop) or (is_integer(loop) and loop in 0..@max_gif_value),
      do: raise(ArgumentError, "last_frame_duration must be a positive duration or nil")

  def handle_init(_ctx, _opts),
    do: raise(ArgumentError, "loop must be nil or an integer in 0..#{@max_gif_value}")

  @impl true
  def handle_stream_format(:input, format, _ctx, %{format: format} = state), do: {[], state}

  def handle_stream_format(
        :input,
        %RawVideo{framerate: nil} = format,
        _ctx,
        %{format: nil} = state
      ),
      do: create_encoder(format, state)

  def handle_stream_format(
        :input,
        %RawVideo{framerate: {num, den}} = format,
        _ctx,
        %{format: nil} = state
      )
      when is_integer(num) and is_integer(den) and num > 0 and den > 0 do
    create_encoder(format, state)
  end

  def handle_stream_format(:input, %RawVideo{}, _ctx, %{format: nil}),
    do: raise(ArgumentError, "GIF requires a positive framerate or nil")

  def handle_stream_format(:input, _format, _ctx, _state),
    do: raise(ArgumentError, "GIF encoder does not support stream-format changes")

  @impl true
  def handle_buffer(:input, %Buffer{pts: nil}, _ctx, %{timing: %{timestamped: true}}),
    do: raise(ArgumentError, "GIF input cannot mix timestamped and untimestamped frames")

  def handle_buffer(:input, %Buffer{pts: pts}, _ctx, %{timing: %{timestamped: false}})
      when is_time(pts),
      do: raise(ArgumentError, "GIF input cannot mix timestamped and untimestamped frames")

  def handle_buffer(
        :input,
        %Buffer{pts: nil} = buffer,
        _ctx,
        %{format: %RawVideo{framerate: {num, den}}, timing: %{index: index} = timing} = state
      ) do
    %{buffer | pts: div(index * den * 1_000_000_000, num)}
    |> queue_frame(%{state | timing: %{timing | timestamped: false}})
  end

  def handle_buffer(:input, %Buffer{pts: pts} = buffer, _ctx, %{timing: timing} = state)
      when is_time(pts),
      do: queue_frame(buffer, %{state | timing: %{timing | timestamped: true}})

  def handle_buffer(:input, _buffer, _ctx, _state),
    do: raise(ArgumentError, "GIF input requires integer PTS or a declared framerate")

  @impl true
  def handle_end_of_stream(:input, _ctx, %{encoder_ref: nil} = state),
    do: {[end_of_stream: :output], state}

  def handle_end_of_stream(:input, _ctx, %{timing: %{pending: nil}} = state) do
    case Native.finish(state.encoder_ref) do
      {:ok, <<>>} ->
        {[buffer: {:output, []}, end_of_stream: :output], %{state | encoder_ref: nil}}

      {:error, reason} ->
        raise ArgumentError, reason
    end
  end

  def handle_end_of_stream(:input, _ctx, %{options: %{last_frame_duration: duration}} = state)
      when is_time(duration),
      do: finish_stream(duration, state)

  def handle_end_of_stream(:input, _ctx, %{timing: %{last_interval: duration}} = state)
      when is_time(duration),
      do: finish_stream(duration, state)

  def handle_end_of_stream(:input, _ctx, %{format: %RawVideo{framerate: {num, den}}} = state),
    do: finish_stream(div(den * 1_000_000_000, num), state)

  def handle_end_of_stream(:input, _ctx, state), do: finish_stream(100_000_000, state)

  defp create_encoder(
         %RawVideo{width: width, height: height, pixel_format: pixel_format} = format,
         %{options: %{loop: loop}} = state
       )
       when is_integer(width) and width in 1..@max_gif_value and
              is_integer(height) and height in 1..@max_gif_value do
    with {:ok, frame_size} <- RawVideo.frame_size(format) do
      {:ok, encoder_ref} =
        Native.create(%{width: width, height: height, pixel_format: pixel_format, loop: loop})

      output = %GIF{width: width, height: height}

      {[stream_format: {:output, output}],
       %{state | encoder_ref: encoder_ref, format: format, frame_size: frame_size}}
    else
      {:error, :invalid_dimensions} ->
        raise ArgumentError, "Invalid dimensions for the input pixel format"
    end
  end

  defp create_encoder(_format, _state),
    do: raise(ArgumentError, "GIF dimensions must be in 1..#{@max_gif_value}")

  defp queue_frame(%Buffer{pts: pts}, %{timing: %{pending: %Buffer{pts: previous}}})
       when pts <= previous,
       do: raise(ArgumentError, "GIF timestamps must increase strictly")

  defp queue_frame(
         %Buffer{payload: payload, pts: pts} = buffer,
         %{timing: %{pending: nil, index: index} = timing, frame_size: frame_size} = state
       )
       when byte_size(payload) == frame_size do
    {[buffer: {:output, []}],
     %{state | timing: %{timing | pending: buffer, origin: pts, index: index + 1}}}
  end

  defp queue_frame(
         %Buffer{payload: payload, pts: pts} = buffer,
         %{
           timing: %{pending: %Buffer{pts: previous}, index: index} = timing,
           frame_size: frame_size
         } = state
       )
       when byte_size(payload) == frame_size do
    output = encode_pending(pts, state)

    {[buffer: {:output, [output]}],
     %{
       state
       | timing: %{timing | pending: buffer, last_interval: pts - previous, index: index + 1}
     }}
  end

  defp queue_frame(_buffer, _state), do: raise(ArgumentError, "invalid_frame_size")

  defp finish_stream(duration, %{timing: %{pending: %Buffer{pts: pts}} = timing} = state) do
    buffer = encode_pending(pts + duration, state)

    case Native.finish(state.encoder_ref) do
      {:ok, trailer} ->
        buffer = %{buffer | payload: buffer.payload <> trailer}

        {[buffer: {:output, [buffer]}, end_of_stream: :output],
         %{state | encoder_ref: nil, timing: %{timing | pending: nil}}}

      {:error, reason} ->
        raise ArgumentError, reason
    end
  end

  defp encode_pending(
         end_pts,
         %{
           encoder_ref: encoder_ref,
           timing: %{pending: %Buffer{pts: pts, payload: pixels}, origin: origin}
         }
       ) do
    # Round cumulative boundaries relative to the first PTS into GIF centiseconds.
    start = div(pts - origin + 5_000_000, 10_000_000)
    stop = div(end_pts - origin + 5_000_000, 10_000_000)

    with delay_cs when delay_cs in 1..@max_gif_value <- stop - start,
         {:ok, payload} <- Native.encode(encoder_ref, pixels, delay_cs) do
      %Buffer{payload: payload, pts: pts}
    else
      {:error, reason} ->
        raise ArgumentError, reason

      _delay ->
        raise ArgumentError, "GIF frame delay must round to 1..#{@max_gif_value} centiseconds"
    end
  end
end
