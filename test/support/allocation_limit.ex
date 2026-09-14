defmodule Membrane.GIF.Test.AllocationLimit do
  @moduledoc false
  use Bundlex.Loader, nif: :allocation_limit

  defnif(set(bytes))
  defnif(reset())

  @spec with_limit(non_neg_integer(), (-> result)) :: result when result: var
  def with_limit(bytes, fun) do
    set(bytes)

    try do
      fun.()
    after
      reset()
    end
  end
end
