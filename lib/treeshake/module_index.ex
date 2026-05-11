defmodule Treeshake.ModuleIndex do
  @moduledoc false

  # Builds a %{module => info} map using reader, analyzer and privates_resolver.
  # Injects hardcoded information.

  @type t :: %{module() => PrivatesResolver.module_info()}

  def build(opts, hardcoded) do
    {ignore_modules, ignore_funs} = Enum.split_with(opts.ignore, &is_atom/1)
    skip_modules = MapSet.new(ignore_modules ++ opts.drop)
    ignore_funs = MapSet.new(ignore_funs)

    opts.ebin_files
    |> Enum.filter(&(Path.extname(&1) == ".beam"))
    |> Enum.reject(&(beam_module(&1) in skip_modules))
    |> process_async(fn path ->
      {:ok, module, core} = Treeshake.Utils.BeamReader.read_core(path)
      info = Treeshake.Utils.BeamAnalyzer.analyze(module, core)
      %{module: module} = info

      info =
        case Map.fetch(hardcoded.calls, module) do
          {:ok, calls} ->
            %{info | functions: Enum.map(info.functions, &%{&1 | calls: calls ++ &1.calls})}

          :error ->
            info
        end

      info =
        case Map.fetch(hardcoded.behaviour_impls, module) do
          {:ok, behaviour_impls} ->
            %{info | behaviour_impls: behaviour_impls ++ info.behaviour_impls}

          :error ->
            info
        end

      functions =
        Enum.map(info.functions, fn fun_info ->
          if {module, fun_info.name, fun_info.arity} in ignore_funs do
            %{fun_info | calls: [], potential_modules: []}
          else
            fun_info
          end
        end)

      info = %{info | functions: functions}

      info = Treeshake.Utils.PrivatesResolver.resolve(info)

      {info.module, info}
    end)
  end

  defp process_async(enum, fun) do
    enum
    |> Task.async_stream(fun, ordered: false, timeout: 15_000)
    |> Map.new(fn {:ok, result} -> result end)
  end

  defp beam_module(beam_path) do
    beam_path |> Path.basename(".beam") |> String.to_atom()
  end
end
