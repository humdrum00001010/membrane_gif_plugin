# GIF demo

Run:

```sh
elixir examples/encode_gif.exs
```

The pipeline encodes a 64×64 GIF cycling through red, green, and blue, one
second per frame, writes it to a temporary file, and prints the file path.
Open the printed path in a browser or image preview to view the animation.

The example builds the Rust backend described in the
[installation notes](../README.md#rust-backend).

```text
GIFDemo.Source → Membrane.GIF.Encoder → Membrane.File.Sink
```

`Mix.install` loads this checkout and the example's file dependency into Mix's
external cache. Running the example leaves the project's `mix.exs` and
`mix.lock` unchanged.
