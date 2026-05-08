defmodule Treeshake.ModuleIndex do
  def build(beam_paths, hardcoded_calls) do
    process_async(beam_paths, fn path ->
      info = Treeshake.Utils.BeamReader.read!(path)

      info =
        case Map.fetch(hardcoded_calls, info.module) do
          {:ok, calls} ->
            %{info | functions: Enum.map(info.functions, &%{&1 | calls: calls ++ &1.calls})}

          :error ->
            info
        end

      info =
        case info do
          %{module: :application_controller} = info ->
            %{info | behaviour_impls: [:gen_server | info.behaviour_impls]}

          info ->
            info
        end

      analysis = Treeshake.Utils.BeamAnalyzer.analyze(info)

      {analysis.module, analysis}
    end)
  end

  defp process_async(enum, fun) do
    enum
    |> Task.async_stream(fun, ordered: false, timeout: 15_000)
    |> Map.new(fn {:ok, result} -> result end)
  end
end
