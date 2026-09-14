# Membrane Template Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_template_plugin.svg)](https://hex.pm/packages/membrane_template_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_template_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_template_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_template_plugin)

This repository contains a template for new plugins.

Check out different branches for other flavors of this template.

It's a part of the [Membrane Framework](https://membrane.stream).

## Installation

### Rust backend

Install Rust 1.88 or newer, Cargo, and a C linker. `mix compile` uses
Rustler to build the native library in `native/membrane_gif`.
The native dependencies are the CPU-based
[`gif`](https://docs.rs/gif) and [`yuv`](https://docs.rs/yuv) crates.
Cargo.lock records their resolved versions. The resulting NIF contains
pixel conversion, palette generation, and GIF writing. The Elixir element
owns frame timing and passes each frame's delay to the NIF.

### Elixir

The package can be installed by adding `membrane_template_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_template_plugin, "~> 0.1.1"}
  ]
end
```

## Usage

See [the Bandit demo](examples/README.md) for a complete pipeline.

The encoder accepts aligned RGB, BGR, RGBA, BGRA, I420, I422, I444, NV12,
NV21, YUY2, YV12, AYUV, I420_10LE, I420_10BE, I422_10LE, I422_10BE,
I444_10LE, and I444_10BE frames. YUV conversion uses limited-range BT.601.
Ten-bit samples occupy 16-bit words in the declared byte order and are
converted to 8-bit RGB. Input alpha is discarded. The GIF crate generates
a separate palette for each frame.

Input PTS values are integer nanoseconds and must increase strictly.
For input with omitted PTS, declare a positive framerate. The Elixir element
holds one frame, rounds cumulative boundaries to centiseconds, and emits
each completed chunk. Each native encode call writes the supplied frame
immediately. Frame delays must fit 1..65535 centiseconds.
The final delay uses `last_frame_duration`, the previous interval, the
declared frame period, or 100 ms, in that order. Empty input emits no GIF
bytes. `loop: 0` repeats forever; `loop: nil` omits the repeat extension.

## Development

Run `mix test` for the real NIF and Membrane pipeline tests. To check the
Rust backend, including decoded colors for every input format:

```sh
cd native/membrane_gif
cargo test --locked
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
```

Rust-analyzer uses `native/membrane_gif/Cargo.toml` for native code.

## Copyright and License

Copyright 2020, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_template_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_template_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
