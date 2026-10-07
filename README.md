# Membrane GIF Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_gif_plugin.svg)](https://hex.pm/packages/membrane_gif_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_gif_plugin)

`Membrane.GIF.Encoder` is a [Membrane](https://membrane.stream) filter that
encodes aligned raw video frames into an animated GIF byte stream.

It's a part of the [Membrane Framework](https://membrane.stream).

## Installation

### Rust backend

Install Rust 1.88 or newer, Cargo, and a C linker. `mix compile` uses
Rustler to build the native library in `native/membrane_gif`.
The native dependency is the CPU-based
[`gif`](https://docs.rs/gif) crate.
Cargo.lock records its resolved version. The resulting NIF contains
palette generation and GIF writing. The Elixir element owns frame timing
and passes each frame's delay to the NIF.

### Elixir

The package can be installed by adding `membrane_gif_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_gif_plugin, "~> 0.1.0"}
  ]
end
```

## Usage

See [the example](examples/README.md) for a complete pipeline.

The encoder accepts aligned RGB and RGBA frames. Convert other pixel formats
beforehand, e.g. with
[membrane_ffmpeg_swscale_plugin](https://hexdocs.pm/membrane_ffmpeg_swscale_plugin/readme.html).
The `gif` crate treats RGBA alpha 0 as transparent and every nonzero value as
fully opaque; partial transparency is not preserved. Pixel conversion and
quantization use the `gif` crate, which generates a separate palette for each frame.

The default `disposal: :background` restores the background after each displayed
frame. `disposal: :keep` retains the canvas beneath transparent pixels.
Fully opaque RGBA frames are accepted with either disposal mode.

The encoder emits `%Membrane.GIF{}` as its output stream format, describing the
GIF's dimensions. The GIF bytes arrive separately in output buffer payloads;
concatenate those payloads to obtain the file.

Input buffers must carry integer PTS timestamps in nanoseconds and must
increase strictly; declare `framerate: nil` in the stream format. The Elixir
element holds one frame, rounds cumulative boundaries to centiseconds, and emits
each completed chunk. Each native encode call writes the supplied frame
immediately. Frame delays must fit 1..65535 centiseconds.
The final delay uses `last_frame_duration`, the previous interval, or 100 ms,
in that order. Empty input emits no GIF bytes. The default `loop: 0` repeats
forever; `loop: nil` omits the repeat extension.

## Development

Run `mix test` for the real NIF and Membrane pipeline tests. To check the
Rust backend, including decoded colors and transparency handling:

```sh
cd native/membrane_gif
cargo test --locked
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
```

Rust-analyzer uses `native/membrane_gif/Cargo.toml` for native code.

## Copyright and License

Copyright 2026, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_gif_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_gif_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
