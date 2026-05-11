defmodule Treeshake.Shaker do
  @moduledoc false

  # Removes modules and functions from a beam file based on call graph
  # and module index.
  # Uses BeamRewriter to change the beams.

  alias Treeshake.Utils.{EmptyModuleStub, BeamRenamer, BeamRewriter}

  @keep_funs [
    module_info: 0,
    module_info: 1,
    __info__: 1,
    __protocol__: 1,
    impl_for!: 1,
    impl_for: 1
  ]

  @spec shake(map, Treeshake.CallGraph.t(), Treeshake.ModuleIndex.t()) :: Treeshake.stats()
  def shake(opts, call_graph, module_index) do
    leave = MapSet.new(opts.leave)
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
      |> Enum.reject(&(beam_module(&1) in leave))

    reachable_mods_funs =
      call_graph
      |> Enum.flat_map(fn {k, v} -> [k | v] end)
      |> Enum.filter(fn {m, f, a} -> get_in(module_index[m].public_functions[{f, a}]) end)
      |> Enum.group_by(fn {m, _f, _a} -> m end, fn {_m, f, a} -> {f, a} end)

    reachable_mods = MapSet.new(reachable_mods_funs, fn {m, _fa} -> m end)

    {to_shake, to_remove} = Enum.split_with(beams, &(beam_module(&1) in reachable_mods))

    modules_shaked =
      process_async(
        to_shake,
        fn path ->
          {shaked, modules_shaked} =
            do_shake(path, reachable_mods_funs, module_index, stub_removed_functions)

          unless opts.dry_run, do: File.write!(path, shaked)
          {beam_module(path), modules_shaked}
        end
      )

    # Handle to_remove (modules that should be tree-shaked completely)
    cond do
      stub_removed_functions ->
        process_async(to_remove, fn path ->
          {shaked, _modules_shaked} = BeamRewriter.keep_funs(path, [], stub_removed_public: true)
          unless opts.dry_run, do: File.write!(path, shaked)
        end)

      stub_removed_modules ->
        module_stub = File.read!(:code.which(EmptyModuleStub))

        for path <- to_remove do
          stub = BeamRenamer.rename(module_stub, beam_module(path))
          unless opts.dry_run, do: File.write!(path, stub)
        end

      opts.dry_run == false ->
        Enum.each(to_remove, &File.rm!/1)

      true ->
        :ok
    end

    %{
      modules_removed: to_remove |> Enum.map(&beam_module/1) |> Enum.sort(),
      modules_shaked: modules_shaked,
      output_dir: output_dir,
      module_index: module_index,
      call_graph: call_graph
    }
  end

  defp do_shake(path, reachable_mods_funs, module_index, stub_removed_functions) do
    module_info = Map.fetch!(module_index, beam_module(path))

    reachable_funs = @keep_funs ++ Map.fetch!(reachable_mods_funs, module_info.module)
    reachable_mapset = MapSet.new(reachable_funs)

    reachable_privs =
      Enum.flat_map(module_info.private_functions, fn {fun, called_by} ->
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
