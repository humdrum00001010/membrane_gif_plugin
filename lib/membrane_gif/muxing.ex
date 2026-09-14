defmodule Membrane.GIF.Muxing do
  @moduledoc false
  import Bitwise
  alias Membrane.Buffer

  @centisecond 10_000_000

  @type t :: %__MODULE__{
          pending: Buffer.t() | nil,
          origin: Membrane.Time.t() | nil,
          last_interval: Membrane.Time.t() | nil,
          last_frame_duration: Membrane.Time.t() | nil,
          nominal_duration: Membrane.Time.t() | nil,
          loop: non_neg_integer() | nil,
          first?: boolean()
        }

  defstruct pending: nil,
            origin: nil,
            last_interval: nil,
            last_frame_duration: nil,
            nominal_duration: nil,
            loop: 0,
            first?: true

  @spec new(non_neg_integer() | nil, Membrane.Time.t() | nil, Membrane.Time.t() | nil) :: t()
  def new(loop, last_frame_duration, nominal_duration) do
    unless is_nil(loop) or (is_integer(loop) and loop in 0..65_535),
      do: raise(ArgumentError, "loop must be nil or an integer in 0..65535")

    unless is_nil(last_frame_duration) or
             (is_integer(last_frame_duration) and last_frame_duration > 0),
           do: raise(ArgumentError, "last_frame_duration must be a positive duration or nil")

    %__MODULE__{
      loop: loop,
      last_frame_duration: last_frame_duration,
      nominal_duration: nominal_duration
    }
  end

  @spec push(Buffer.t(), t()) :: {[Buffer.t()], t()}
  def push(%Buffer{pts: pts} = buffer, %{pending: nil} = state) do
    {[], %{state | pending: buffer, origin: pts}}
  end

  def push(%Buffer{pts: pts} = buffer, state) do
    interval = pts - state.pending.pts
    unless interval > 0, do: raise(ArgumentError, "GIF timestamps must increase strictly")
    {output, state} = emit_pending(pts, state)
    {[output], %{state | pending: buffer, last_interval: interval}}
  end

  @spec finish(t()) :: {[Buffer.t()], t()}
  def finish(%{pending: nil} = state), do: {[], state}

  def finish(state) do
    duration =
      state.last_frame_duration || state.last_interval ||
        state.nominal_duration || 100_000_000

    {output, state} = emit_pending(state.pending.pts + duration, state)
    {[%{output | payload: output.payload <> <<0x3B>>}], %{state | pending: nil}}
  end

  defp emit_pending(end_pts, state) do
    start = centiseconds(state.pending.pts - state.origin)
    delay = centiseconds(end_pts - state.origin) - start

    unless delay in 1..65_535,
      do: raise(ArgumentError, "GIF frame delay must round to 1..65535 centiseconds")

    payload = mux_packet(state.pending.payload, delay, state.first?, state.loop)
    {%{state.pending | payload: payload}, %{state | first?: false}}
  end

  defp centiseconds(ns), do: div(ns + div(@centisecond, 2), @centisecond)

  # FFmpeg's first packet contains a 13-byte header followed by its global
  # color table. Locate the GCE structurally, never by searching image bytes.
  # Only accepts packets from our FFmpeg GIF encoder, which emits no loop
  # extension. Existing GIFs with NETSCAPE2.0, ANIMEXTS1.0, or other extensions
  # before the GCE require extension-block parsing and are not supported here.
  defp mux_packet(
         <<"GIF89a", _w::16-little, _h::16-little, flags, _bg, _aspect, rest::binary>> = packet,
         delay,
         true,
         loop
       ) do
    palette_size = if (flags &&& 0x80) != 0, do: 3 * (1 <<< ((flags &&& 7) + 1)), else: 0
    <<_palette::binary-size(^palette_size), frame::binary>> = rest
    header = binary_part(packet, 0, 13 + palette_size)

    extension =
      if is_nil(loop) do
        <<>>
      else
        <<0x21, 0xFF, 11, "NETSCAPE2.0", 3, 1, loop::16-little, 0>>
      end

    header <> extension <> patch_delay(frame, delay)
  end

  defp mux_packet(packet, delay, false, _loop), do: patch_delay(packet, delay)

  defp patch_delay(<<0x21, 0xF9, 4, flags, _delay::16-little, index, 0, rest::binary>>, delay),
    do: <<0x21, 0xF9, 4, flags, delay::16-little, index, 0, rest::binary>>
end
