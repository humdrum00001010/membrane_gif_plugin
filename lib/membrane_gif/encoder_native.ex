defmodule Membrane.GIF.Encoder.Native do
  @moduledoc false
  use Rustler, otp_app: :membrane_template_plugin, crate: :membrane_gif

  @type state :: reference()

  @type create_options :: %{
          width: pos_integer(),
          height: pos_integer(),
          pixel_format: Membrane.RawVideo.pixel_format(),
          loop: non_neg_integer() | nil
        }

  @spec create(create_options()) :: {:ok, state()} | {:error, String.t()}
  def create(_options), do: :erlang.nif_error(:nif_not_loaded)

  @spec encode(state(), binary(), pos_integer()) :: {:ok, binary()} | {:error, String.t()}
  def encode(_state, _pixels, _delay_cs), do: :erlang.nif_error(:nif_not_loaded)

  @spec finish(state()) :: {:ok, binary()} | {:error, String.t()}
  def finish(_state), do: :erlang.nif_error(:nif_not_loaded)
end
