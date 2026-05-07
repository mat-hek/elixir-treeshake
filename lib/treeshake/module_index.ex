defmodule Treeshake.ModuleIndex do
  def build(beam_paths) do
    process_async(beam_paths, fn path ->
      analysis =
        path
        |> Treeshake.Utils.BeamReader.read!()
        |> case do
          %{module: :application_controller} = info ->
            %{info | behaviour_impls: [:gen_server | info.behaviour_impls]}

          info ->
            info
        end
        |> Treeshake.Utils.BeamAnalyzer.analyze()

      {analysis.module, analysis}
    end)
  end

  defp process_async(enum, fun) do
    enum
    |> Task.async_stream(fun, ordered: false, timeout: 15_000)
    |> Map.new(fn {:ok, result} -> result end)
  end
end
