# GIF demo

Run:

```sh
elixir examples/encode_gif.exs
```

Open <http://127.0.0.1:4000>. The 64×64 GIF cycles through red, green, and blue,
one second each. Stop the script with Ctrl-C.

The example uses the default precompiled FFmpeg bundle described in the
[installation notes](../README.md#ffmpeg).

```text
Membrane.Testing.Source → Membrane.GIF.Encoder → Membrane.File.Sink
```

Bandit starts first. Each GET to `/` starts a fresh Membrane
pipeline. `Testing.Source` feeds three raw frames to the encoder. The request
waits for the sink to finish, sends the GIF, then stops the pipeline and deletes
the temporary file. Bandit handles other requests concurrently.

`use Plug.Router` supplies the routing macros. `Mix.install` loads this checkout
and the example's HTTP/file dependencies into Mix's external cache. Running the
example leaves the project's `mix.exs` and `mix.lock` unchanged.
