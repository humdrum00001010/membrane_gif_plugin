defmodule Membrane.GIF.Test.GIFBlocks do
  @moduledoc false
  import Bitwise

  @spec parse(binary()) :: map()
  def parse(<<"GIF89a", width::16-little, height::16-little, flags, _bg, _aspect, rest::binary>>) do
    palette_size = if (flags &&& 0x80) != 0, do: 3 * (1 <<< ((flags &&& 7) + 1)), else: 0
    rest = binary_part(rest, palette_size, byte_size(rest) - palette_size)
    blocks(rest, %{width: width, height: height, delays: [], loop: nil, images: 0})
  end

  defp blocks(<<0x3B>>, result), do: %{result | delays: Enum.reverse(result.delays)}

  defp blocks(<<0x21, 0xF9, 4, _flags, delay::16-little, _index, 0, rest::binary>>, result),
    do: blocks(rest, %{result | delays: [delay | result.delays]})

  defp blocks(<<0x21, 0xFF, 11, "NETSCAPE2.0", 3, 1, loop::16-little, 0, rest::binary>>, result),
    do: blocks(rest, %{result | loop: loop})

  defp blocks(
         <<0x2C, _left::16-little, _top::16-little, _width::16-little, _height::16-little, flags,
           rest::binary>>,
         result
       ) do
    palette_size = if (flags &&& 0x80) != 0, do: 3 * (1 <<< ((flags &&& 7) + 1)), else: 0
    <<_code_size, data::binary>> = binary_part(rest, palette_size, byte_size(rest) - palette_size)
    blocks(skip_subblocks(data), %{result | images: result.images + 1})
  end

  defp skip_subblocks(<<0, rest::binary>>), do: rest

  defp skip_subblocks(<<size, rest::binary>>),
    do: skip_subblocks(binary_part(rest, size, byte_size(rest) - size))
end
