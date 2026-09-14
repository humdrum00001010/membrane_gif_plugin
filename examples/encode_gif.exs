Mix.install([
  {:membrane_gif_plugin, path: Path.expand("..", __DIR__)},
  {:membrane_file_plugin, "~> 0.17.5"}
])

# Membrane logs pipeline lifecycle events at :debug level; keep example output clean.
Logger.configure(level: :warning)

defmodule GIFDemo.Source do
  use Membrane.Source

  def_output_pad :output, accepted_format: Membrane.RawVideo, flow_control: :manual

  @impl true
  def handle_init(_ctx, _options) do
    frames =
      for {rgb, index} <- Enum.with_index([<<255, 0, 0>>, <<0, 255, 0>>, <<0, 0, 255>>]) do
        %Membrane.Buffer{payload: :binary.copy(rgb, 64 * 64), pts: index * 1_000_000_000}
      end

    {[], frames}
  end

  @impl true
  def handle_playing(_ctx, frames) do
    format = %Membrane.RawVideo{
      width: 64,
      height: 64,
      pixel_format: :RGB,
      aligned: true,
      framerate: nil
    }

    {[stream_format: {:output, format}], frames}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, frames) do
    {buffers, remaining} = Enum.split(frames, size)
    actions = [buffer: {:output, buffers}]
    actions = if remaining == [], do: actions ++ [end_of_stream: :output], else: actions
    {actions, remaining}
  end
end

defmodule GIFDemo.Pipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, {owner, output}) do
    spec =
      child(:source, GIFDemo.Source)
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

output = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}.gif")

{:ok, _supervisor, pipeline} =
  Membrane.Pipeline.start_link(GIFDemo.Pipeline, {self(), output})

try do
  receive do
    {:gif_complete, ^pipeline} ->
      IO.puts("GIF(output): #{inspect(output)}")
  after
    30_000 -> IO.puts("GIF: timeout")
  end
after
  Membrane.Pipeline.terminate(pipeline)
end
