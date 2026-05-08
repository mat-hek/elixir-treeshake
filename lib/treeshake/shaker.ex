defmodule Treeshake.Shaker do
  @keep_funs [
    module_info: 0,
    module_info: 1,
    __info__: 1,
    __protocol__: 1,
    impl_for!: 1,
    impl_for: 1
  ]

  [{_name, module_stub}] =
    quote do
      defmodule Treeshake.EmptyModuleStub do
      end
    end
    |> Code.compile_quoted()

  @module_stub module_stub

  def shake(opts, call_graph, module_index) do
    not_touch = MapSet.new(opts.ignore ++ opts.leave)
    stub_removed_functions = Map.get(opts, :stub_removed_functions, false)
    stub_removed_modules = Map.get(opts, :stub_removed_modules, false)

    output_dir = Map.get(opts, :output_dir)

    ebin_files =
      if opts.dry_run do
        opts.ebin_files
      else
        File.mkdir_p!(output_dir)

        Enum.map(opts.ebin_files, fn src ->
          output_path = Path.join(output_dir, Path.basename(src))
          File.copy!(src, output_path)
          output_path
        end)
      end

    beams =
      ebin_files
      |> Enum.filter(&(Path.extname(&1) == ".beam"))
      |> Enum.reject(&(beam_module(&1) in not_touch))

    reachable_mods_funs =
      call_graph
      |> Enum.flat_map(fn {k, v} -> [k | v] end)
      |> Enum.filter(fn {m, f, a} -> get_in(module_index[m].public_functions[{f, a}]) end)
      |> Enum.group_by(fn {m, _f, _a} -> m end, fn {_m, f, a} -> {f, a} end)

    reachable_mods = MapSet.new(reachable_mods_funs, fn {m, _fa} -> m end)

    {to_shake, to_remove} = Enum.split_with(beams, &(beam_module(&1) in reachable_mods))

    functions_removed =
      process_async(
        to_shake,
        fn path ->
          {shaked, functions_removed} =
            do_shake(path, reachable_mods_funs, module_index, stub_removed_functions)

          unless opts.dry_run, do: File.write!(path, shaked)
          {beam_module(path), functions_removed}
        end
      )

    {beams_removed, functions_removed} =
      if stub_removed_functions do
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

    beams_removed =
      if stub_removed_modules do
        for beam <- beams_removed do
          stub = Treeshake.Utils.BeamRenamer.rename(@module_stub, beam_module(beam))
          unless opts.dry_run, do: File.write!(beam, stub)
        end

        []
      else
        beams_removed
      end

    %{
      modules_removed: beams_removed |> Enum.map(&beam_module/1) |> Enum.sort(),
      beams_removed: beams_removed |> Enum.sort(),
      functions_removed:
        functions_removed
        |> Enum.flat_map(fn {m, fa} ->
          Enum.map(fa, fn {f, a} -> {m, f, a} end)
        end)
        |> Enum.sort(),
      modules_rewritten: to_shake |> Enum.map(&beam_module/1) |> Enum.sort(),
      modules_ignored: not_touch |> Enum.sort(),
      output_dir: output_dir
    }
  end

  defp do_shake(path, reachable_mods_funs, module_index, stub_removed_functions) do
    analysis = Map.fetch!(module_index, beam_module(path))

    reachable_funs = @keep_funs ++ Map.fetch!(reachable_mods_funs, analysis.module)
    reachable_mapset = MapSet.new(reachable_funs)

    reachable_privs =
      Enum.flat_map(analysis.private_functions, fn {fun, called_by} ->
        if Enum.any?(called_by, &(&1 in reachable_mapset)), do: [fun], else: []
      end)

    Treeshake.Utils.BeamRewriter.keep_funs(path, reachable_funs ++ reachable_privs,
      stub_removed_public: stub_removed_functions
    )
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
