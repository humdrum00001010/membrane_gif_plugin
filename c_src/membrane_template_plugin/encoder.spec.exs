module Membrane.GIF.Encoder.Native

state_type "State"

type pixel_format :: :I420 | :I422 | :I444 | :RGB | :BGR | :RGBA | :BGRA | :NV12 | :NV21 | :YUY2

spec create(width :: int, height :: int, pix_fmt :: pixel_format) ::
       {:ok :: label, state} | {:error :: label, reason :: atom}

spec encode(payload, state) :: {:ok :: label, packets :: [payload]} | {:error :: label, reason :: atom}

spec flush(state) :: {:ok :: label, packets :: [payload]} | {:error :: label, reason :: atom}

dirty :cpu, [:create, :encode, :flush]
