defmodule Membrane.GIF.Encoder.Native do
  @moduledoc false
  use Rustler, otp_app: :membrane_gif_plugin, crate: :membrane_gif

  @type state :: reference()

  @type create_options :: %{
          width: pos_integer(),
          height: pos_integer(),
          pixel_format: :RGB | :RGBA,
          loop: non_neg_integer() | nil
        }

  @spec create(create_options()) :: {:ok, state()}
  def create(_options), do: :erlang.nif_error(:nif_not_loaded)

  @spec encode(state(), binary(), pos_integer()) :: {:ok, binary()}
  def encode(_state, _pixels, _delay_cs), do: :erlang.nif_error(:nif_not_loaded)

  @spec finish(state()) :: {:ok, binary()}
  def finish(_state), do: :erlang.nif_error(:nif_not_loaded)
end
