defmodule Membrane.GIF do
  @moduledoc """
  Stream format describing the GIF byte stream produced by `Membrane.GIF.Encoder`.

  `width` and `height` describe its fixed frame dimensions. The GIF bytes are
  carried separately in output `Membrane.Buffer` payloads. Concatenating those
  payloads produces one GIF file; individual buffers are not standalone images.
  """

  defstruct width: nil, height: nil

  @type t :: %__MODULE__{width: pos_integer() | nil, height: pos_integer() | nil}
end
