defmodule Membrane.GIF do
  @moduledoc """
  A GIF byte stream. Concatenating all output buffer payloads produces one GIF
  file; individual buffers are not standalone images. Dimensions stay fixed.
  """

  defstruct width: 0, height: 0

  @type t :: %__MODULE__{width: pos_integer(), height: pos_integer()}
end
