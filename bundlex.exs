defmodule Membrane.GIF.BundlexProject do
  use Bundlex.Project

  def project() do
    [
      natives: natives() ++ allocation_test_native()
    ]
  end

  defp allocation_test_native do
    if Mix.env() == :test do
      [
        allocation_limit:
          natives()[:encoder]
          |> Keyword.delete(:preprocessor)
          |> Keyword.put(:sources, ["../../test/support/allocation_limit.c"])
      ]
    else
      []
    end
  end

  defp natives() do
    [
      encoder: [
        interface: :nif,
        sources: ["encoder.c"],
        os_deps: [
          ffmpeg: [
            {:precompiled,
             Membrane.PrecompiledDependencyProvider.get_dependency_url(:ffmpeg, version: "6.0.1"),
             ["libavcodec", "libavutil", "libswscale"]},
            {:pkg_config, ["libavcodec", "libavutil", "libswscale"]}
          ]
        ],
        preprocessor: Unifex
      ]
    ]
  end
end
