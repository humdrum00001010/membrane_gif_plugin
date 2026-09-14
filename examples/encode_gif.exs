Mix.install([
  {:membrane_template_plugin, path: Path.expand("..", __DIR__)},
  {:membrane_file_plugin, "~> 0.17.5"},
  {:bandit, "~> 1.12.5"}
])

defmodule GIFDemo.Pipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, {owner, output}) do
    frames =
      for rgb <- [<<255, 0, 0>>, <<0, 255, 0>>, <<0, 0, 255>>],
          do: :binary.copy(rgb, 64 * 64)

    source = %Membrane.Testing.Source{
      output: frames,
      stream_format: %Membrane.RawVideo{
        width: 64,
        height: 64,
        pixel_format: :RGB,
        aligned: true,
        framerate: {1, 1}
      }
    }

    spec =
      child(:source, source)
      |> child(:encoder, %Membrane.GIF.Encoder{loop: 0})
      |> child(:sink, %Membrane.File.Sink{location: output})

    {[spec: spec], owner}
  end

  @impl true
  def handle_element_end_of_stream(:sink, :input, _ctx, owner) do
    send(owner, {:gif_complete, self()})
    {[], owner}
  end

  def handle_element_end_of_stream(_element, _pad, _ctx, owner), do: {[], owner}
end

defmodule GIFDemo.Preview do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    output = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}.gif")

    {:ok, _supervisor, pipeline} =
      Membrane.Pipeline.start_link(GIFDemo.Pipeline, {self(), output})

    try do
      # send once, replays in frontend
      receive do
        {:gif_complete, ^pipeline} ->
          conn
          |> put_resp_content_type("image/gif")
          |> send_file(200, output)
      after
        30_000 -> send_resp(conn, 504, "GIF pipeline timed out")
      end
    after
      Membrane.Pipeline.terminate(pipeline, force?: true)
      File.rm!(output)
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end

{:ok, _server} =
  Bandit.start_link(plug: GIFDemo.Preview, ip: {127, 0, 0, 1}, port: 4000)

Process.sleep(:infinity)
