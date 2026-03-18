defmodule Treeshake.BeamRewriter do
  @moduledoc """
  Removes unreachable modules and functions from compiled BEAM files.

  ## Module-level removal

  If every function in a module is unreachable, the entire `.beam` file is
  deleted (or omitted from the output directory). This is the most impactful
  reduction and requires no BEAM internals knowledge.

  ## Function-level removal

  For modules that are *partially* live (some functions are reachable, others
  are not), this module attempts to strip the dead functions by:

  1. Reading the `abstract_code` chunk (present when the BEAM was compiled with
     `debug_info`, which is Mix's default).
  2. Filtering out dead `{:function, ...}` and their associated `:spec`
     attributes from the abstract syntax tree.
  3. Recompiling the filtered AST with `:compile.forms/2`.

  If `abstract_code` is not available (e.g. stripped production builds), the
  module is left unchanged and listed under `:skipped_no_debug_info` in the
  returned statistics.

  ## Exported vs private functions

  By default only *unexported* (private) dead functions are removed, since
  removing exported functions changes a module's public API and could break
  dynamic calls (`apply/3`, hot code loading, etc.). Pass `remove_exports: true`
  to also remove unreachable exported functions.

  ## Options

    * `:output_dir`      — write results here instead of modifying files in place.
    * `:dry_run`         — compute statistics without touching any file.
    * `:keep_debug_info` — keep the `debug_info` chunk in rewritten BEAMs (default `true`).
    * `:remove_exports`  — also strip unreachable exported functions (default `false`).
    * `:verbose`         — print each removed item (default `false`).
  """

  alias Treeshake.Project

  @type mfa_tuple :: {atom(), atom(), non_neg_integer()}
  @type stats :: %{
          modules_removed: [atom()],
          functions_removed: [mfa_tuple()],
          modules_rewritten: [atom()],
          skipped_no_debug_info: [atom()]
        }

  @doc """
  Walk all BEAM files in `project`, remove dead code according to `reachable`,
  and return a statistics map.
  """
  @spec rewrite(Project.t(), map(), keyword()) :: stats()
  def rewrite(project, reachable, opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir)
    dry_run = Keyword.get(opts, :dry_run, false)

    if output_dir && not dry_run do
      File.mkdir_p!(output_dir)
      Enum.each(project.all_beam_files, fn src ->
        File.copy!(src, Path.join(output_dir, Path.basename(src)))
      end)
    end

    empty_stats = %{
      modules_removed: [],
      functions_removed: [],
      modules_rewritten: [],
      skipped_no_debug_info: []
    }

    Enum.reduce(project.all_beam_files, empty_stats, fn beam_path, stats ->
      module = Project.module_from_beam(beam_path)
      effective = effective_path(beam_path, output_dir)

      if MapSet.member?(reachable.modules, module) do
        process_live_module(effective, module, reachable, stats, opts)
      else
        remove_dead_module(effective, module, stats, opts)
      end
    end)
  end

  @doc """
  Remove a specific set of functions from a BEAM file.

  Requires the file to have been compiled with `debug_info`. Returns `:ok` on
  success or `{:error, reason}` on failure.
  """
  @spec remove_functions(String.t(), atom(), MapSet.t(mfa_tuple()), keyword()) ::
          :ok | {:error, term()}
  def remove_functions(beam_path, module, funcs_to_remove, opts \\ []) do
    charlist = String.to_charlist(beam_path)

    case :beam_lib.chunks(charlist, [:abstract_code]) do
      {:ok, {^module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
        rewrite_via_abstract_code(beam_path, module, forms, funcs_to_remove, opts)

      {:ok, {^module, [{:abstract_code, :no_debug_info}]}} ->
        {:error, :no_abstract_code}

      {:ok, {^module, [{:abstract_code, _}]}} ->
        {:error, :no_abstract_code}

      _ ->
        {:error, :no_abstract_code}
    end
  end

  # ---- private helpers ----

  defp effective_path(beam_path, nil), do: beam_path
  defp effective_path(beam_path, dir), do: Path.join(dir, Path.basename(beam_path))

  defp remove_dead_module(beam_path, module, stats, opts) do
    verbose_log(opts, "  [-] #{module} (whole module)")

    unless Keyword.get(opts, :dry_run, false) do
      File.rm!(beam_path)
    end

    Map.update!(stats, :modules_removed, &[module | &1])
  end

  defp process_live_module(beam_path, module, reachable, stats, opts) do
    remove_exports = Keyword.get(opts, :remove_exports, false)
    dry_run = Keyword.get(opts, :dry_run, false)

    dead = find_dead_functions(beam_path, module, reachable, remove_exports)

    if Enum.empty?(dead) do
      stats
    else
      Enum.each(dead, fn {m, f, a} ->
        verbose_log(opts, "  [-] #{m}.#{f}/#{a}")
      end)

      if dry_run do
        Map.update!(stats, :functions_removed, &(dead ++ &1))
      else
        dead_set = MapSet.new(dead)

        case remove_functions(beam_path, module, dead_set, opts) do
          :ok ->
            stats
            |> Map.update!(:functions_removed, &(dead ++ &1))
            |> Map.update!(:modules_rewritten, &[module | &1])

          {:error, :no_abstract_code} ->
            Map.update!(stats, :skipped_no_debug_info, &[module | &1])

          {:error, reason} ->
            IO.warn("Failed to rewrite #{inspect(module)}: #{inspect(reason)}")
            stats
        end
      end
    end
  end

  # Returns the list of dead (unreachable) MFAs in a module.
  defp find_dead_functions(beam_path, module, reachable, remove_exports) do
    exports = if remove_exports, do: MapSet.new(), else: exports_for(beam_path, module)

    functions_for(beam_path, module)
    |> Enum.reject(fn {_m, f, a} = mfa ->
      MapSet.member?(reachable.mfas, mfa) or MapSet.member?(exports, {f, a})
    end)
  end

  defp rewrite_via_abstract_code(beam_path, module, forms, funcs_to_remove, opts) do
    new_forms =
      Enum.reject(forms, fn
        {:function, _line, name, arity, _clauses} ->
          MapSet.member?(funcs_to_remove, {module, name, arity})

        # Strip the typespec for removed functions too.
        {:attribute, _line, :spec, {{name, arity}, _spec}} ->
          MapSet.member?(funcs_to_remove, {module, name, arity})

        _ ->
          false
      end)

    compile_opts =
      [:return_errors, :return_warnings] ++
        if Keyword.get(opts, :keep_debug_info, true), do: [:debug_info], else: []

    case :compile.forms(new_forms, compile_opts) do
      {:ok, ^module, binary, _warnings} ->
        File.write!(beam_path, binary)
        :ok

      {:error, errors, _warnings} ->
        {:error, {:compile_error, format_errors(errors)}}
    end
  end

  # Returns all MFAs defined in the BEAM (prefers abstract_code for private fns).
  defp functions_for(beam_path, module) do
    charlist = String.to_charlist(beam_path)

    case :beam_lib.chunks(charlist, [:abstract_code]) do
      {:ok, {^module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
        Enum.flat_map(forms, fn
          {:function, _line, name, arity, _clauses} -> [{module, name, arity}]
          _ -> []
        end)

      _ ->
        case :beam_lib.chunks(charlist, [:exports]) do
          {:ok, {^module, [{:exports, exports}]}} ->
            Enum.map(exports, fn {f, a} -> {module, f, a} end)

          _ ->
            []
        end
    end
  end

  defp exports_for(beam_path, module) do
    charlist = String.to_charlist(beam_path)

    case :beam_lib.chunks(charlist, [:exports]) do
      {:ok, {^module, [{:exports, exports}]}} -> MapSet.new(exports)
      _ -> MapSet.new()
    end
  end

  defp verbose_log(opts, msg) do
    if Keyword.get(opts, :verbose, false), do: IO.puts(msg)
  end

  defp format_errors(errors) do
    Enum.flat_map(errors, fn {_file, errs} ->
      Enum.map(errs, fn {line, mod, desc} ->
        "line #{line}: #{mod.format_error(desc)}"
      end)
    end)
  end
end
