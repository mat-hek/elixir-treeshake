defmodule Treeshake.ModuleIndex do
  def build(beam_paths, hardcoded) do
    process_async(beam_paths, fn path ->
      info = Treeshake.Utils.BeamParser.read!(path)

      info =
        case Map.fetch(hardcoded.calls, info.module) do
          {:ok, calls} ->
            %{info | functions: Enum.map(info.functions, &%{&1 | calls: calls ++ &1.calls})}

          :error ->
            info
        end

      info =
        case Map.fetch(hardcoded.behaviour_impls, info.module) do
          {:ok, behaviour_impls} ->
            %{info | behaviour_impls: behaviour_impls ++ info.behaviour_impls}

          :error ->
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
