defmodule Treeshake.Shaker do
  @non_treeshakable_apps [:erts, :stdlib, :kernel, :logger]

  @keep_funs [
    module_info: 0,
    module_info: 1,
    __info__: 1,
    __protocol__: 1,
    impl_for!: 1,
    impl_for: 1
  ]

  def shake(all_beams, cg, opts) do
    non_treeshakable_modules = Map.get(opts, :non_treeshakable_modules, [])
    stub_removed = Map.get(opts, :stub_removed, false)

    non_treeshakable_modules =
      MapSet.new(non_treeshakable_modules ++ non_treeshakable_stdlib_modules())

    output_dir = Map.get(opts, :output_dir)

    all_beams =
      if opts.dry_run or output_dir == nil do
        all_beams
      else
        File.mkdir_p!(output_dir)

        Enum.map(all_beams, fn src ->
          output_path = Path.join(output_dir, Path.basename(src))
          File.copy!(src, output_path)
          output_path
        end)
      end

    all_beams = Enum.reject(all_beams, &(beam_module(&1) in non_treeshakable_modules))

    reachable_mods_funs =
      cg
      |> Enum.flat_map(fn {k, v} -> [k | v] end)
      |> Enum.group_by(fn {m, _f, _a} -> m end, fn {_m, f, a} -> {f, a} end)

    reachable_mods = MapSet.new(reachable_mods_funs, fn {m, _fa} -> m end)

    {to_shake, to_remove} = Enum.split_with(all_beams, &(beam_module(&1) in reachable_mods))

    functions_removed =
      process_async(
        to_shake,
        fn path ->
          {shaked, functions_removed} = do_shake(path, reachable_mods_funs)
          unless opts.dry_run, do: File.write!(path, shaked)
          {beam_module(path), functions_removed}
        end
      )

    {to_remove, functions_removed} =
      if stub_removed do
        functions_stubbed =
          process_async(to_remove, fn path ->
            {shaked, functions_removed} =
              Treeshake.Utils.BeamRewriter.keep_funs(path, [], stub_removed_public: true)

            unless opts.dry_run, do: File.write!(path, shaked)
            {beam_module(path), functions_removed}
          end)

        {[], Map.merge(functions_removed, functions_stubbed)}
      else
        unless opts.dry_run, do: Enum.each(to_remove, &File.rm!/1)
        {to_remove, functions_removed}
      end

    %{
      modules_removed: to_remove |> Enum.map(&beam_module/1) |> Enum.sort(),
      beams_removed: to_remove |> Enum.sort(),
      functions_removed:
        functions_removed
        |> Enum.flat_map(fn {m, fa} ->
          Enum.map(fa, fn {f, a} -> {m, f, a} end)
        end)
        |> Enum.sort(),
      modules_rewritten: to_shake |> Enum.map(&beam_module/1) |> Enum.sort(),
      modules_ignored: non_treeshakable_modules |> Enum.sort()
    }
  end

  defp do_shake(path, reachable_mods_funs) do
    analysis =
      path |> Treeshake.Utils.BeamReader.read!() |> Treeshake.Utils.BeamAnalyzer.analyze()

    reachable_funs = @keep_funs ++ Map.fetch!(reachable_mods_funs, analysis.module)
    reachable_mapset = MapSet.new(reachable_funs)

    reachable_privs =
      Enum.flat_map(analysis.private_functions, fn {fun, called_by} ->
        if Enum.any?(called_by, &(&1 in reachable_mapset)), do: [fun], else: []
      end)

    Treeshake.Utils.BeamRewriter.keep_funs(path, reachable_funs ++ reachable_privs)
  end

  defp non_treeshakable_stdlib_modules() do
    @non_treeshakable_apps
    |> Enum.flat_map(fn app ->
      Path.wildcard(Path.join(:code.lib_dir(app, :ebin), "*.beam"))
    end)
    |> Enum.map(&beam_module/1)
  end

  defp beam_module(beam_path) do
    beam_path |> Path.basename(".beam") |> String.to_atom()
  end

  defp process_async(enum, fun) do
    enum
    |> Task.async_stream(fun, ordered: false, timeout: 15_000)
    |> Map.new(fn {:ok, result} -> result end)
  end
end
