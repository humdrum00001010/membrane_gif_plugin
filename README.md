# Membrane Template Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_template_plugin.svg)](https://hex.pm/packages/membrane_template_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_template_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_template_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_template_plugin)

This repository contains a template for new plugins.

Check out different branches for other flavors of this template.

It's a part of the [Membrane Framework](https://membrane.stream).

## Installation

### FFmpeg

Bundlex fetches FFmpeg through `Membrane.PrecompiledDependencyProvider`,
then falls back to `pkg-config` for installed `libavcodec`, `libavutil`,
and `libswscale`. The default provider tag is `6.0.1`, matching the
[H264 FFmpeg](https://github.com/membraneframework/membrane_h264_ffmpeg_plugin/blob/master/bundlex.exs)
and [SWScale](https://github.com/membraneframework/membrane_ffmpeg_swscale_plugin/blob/master/bundlex.exs)
plugins.

Keep FFmpeg version updates aligned with these plugins. The current
bundle has known security concerns; review
[FFmpeg security updates](https://ffmpeg.org/security.html) for deployment.

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

TODO

## Native editor support

`compile_flags.txt` contains common flags and repository-relative includes.
Run `mix compile.bundlex --generate-lsp-config` to generate a local
`compile_commands.json` with the Erlang and FFmpeg include paths.
That command also rewrites `compile_flags.txt`; keep its machine-specific
paths out of commits.

## Copyright and License

Copyright 2020, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_template_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_template_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
