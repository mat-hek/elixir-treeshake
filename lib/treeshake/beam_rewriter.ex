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

  All unreachable functions — including exported ones — are removed. Certain
  functions are always preserved regardless of reachability:

  * `__info__/1`, `module_info/0`, `module_info/1` — Elixir/Erlang internals
    required by the VM.
  * Behaviour callbacks declared in the module (via `@behaviour` / `-behaviour`
    attributes) — removing these would violate the behaviour contract and cause
    compile errors during BEAM rewriting.

  ## Options

    * `:output_dir`      — write results here instead of modifying files in place.
    * `:dry_run`         — compute statistics without touching any file.
    * `:keep_debug_info` — keep the `debug_info` chunk in rewritten BEAMs (default `true`).
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
  def rewrite(all_beams, reachable, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    output_dir = Keyword.get(opts, :output_dir)

    all_beams =
      if dry_run or output_dir == nil do
        all_beams
      else
        File.mkdir_p!(output_dir)

        Enum.map(all_beams, fn src ->
          output_path = Path.join(output_dir, Path.basename(src))
          File.copy!(src, output_path)
          output_path
        end)
      end

    empty_stats = %{
      modules_removed: [],
      beams_removed: [],
      functions_removed: [],
      modules_rewritten: [],
      skipped_no_debug_info: []
    }

    Enum.reduce(all_beams, empty_stats, fn beam_path, stats ->
      module = beam_path |> Path.basename(".beam") |> String.to_atom()

      if MapSet.member?(reachable.modules, module) do
        process_live_module(beam_path, module, reachable, stats, opts)
      else
        remove_dead_module(beam_path, module, stats, opts)
      end
    end)
  end

  @doc """
  Remove a specific set of functions from a BEAM file.

  Requires the file to have been compiled with `debug_info`. Returns `:ok` on
  success or `{:error, reason}` on failure.
  """
  @spec remove_functions(String.t(), MapSet.t(mfa_tuple()), keyword()) ::
          :ok | {:error, term()}
  def remove_functions(beam_path, funcs_to_remove, opts \\ []) do
    {:ok, module, forms} = get_abstract_code(beam_path)
    rewrite_via_abstract_code(beam_path, module, forms, funcs_to_remove, opts)
  end

  defp remove_dead_module(beam_path, module, stats, opts) do
    verbose_log(opts, "  [-] #{module} (whole module)")

    unless Keyword.get(opts, :dry_run, false) do
      File.rm!(beam_path)
    end

    stats
    |> Map.update!(:modules_removed, &[module | &1])
    |> Map.update!(:beams_removed, &[beam_path | &1])
  end

  defp process_live_module(beam_path, module, reachable, stats, opts) do
    dead = find_dead_functions(beam_path, reachable)

    if Enum.empty?(dead) do
      stats
    else
      Enum.each(dead, fn {m, f, a} ->
        verbose_log(opts, "  [-] #{m}.#{f}/#{a}")
      end)

      dead_set = MapSet.new(dead)

      case remove_functions(beam_path, dead_set, opts) do
        :ok ->
          stats
          |> Map.update!(:functions_removed, &(dead ++ &1))
          |> Map.update!(:modules_rewritten, &[module | &1])

        {:error, reason} ->
          IO.warn("Failed to rewrite #{inspect(module)}: #{inspect(reason)}")
          stats
      end
    end
  end

  # Always-protected function signatures: Elixir/Erlang internals that must
  # remain in every module or the VM / compiler will reject the BEAM.
  @protected_fns MapSet.new([{:__info__, 1}, {:module_info, 0}, {:module_info, 1}])

  # Returns the list of dead (unreachable) MFAs in a module.
  defp find_dead_functions(beam_path, reachable) do
    protected = behaviour_callbacks(beam_path)

    functions_for(beam_path)
    |> Enum.reject(fn {_m, f, a} = mfa ->
      MapSet.member?(reachable.mfas, mfa) or
        MapSet.member?(@protected_fns, {f, a}) or
        MapSet.member?(protected, {f, a})
    end)
  end

  # Returns a MapSet of {fun, arity} pairs that are required callbacks of any
  # behaviour declared in the module's abstract code.
  defp behaviour_callbacks(beam_path) do
    {:ok, _module, forms} = get_abstract_code(beam_path)

    forms
    |> Enum.flat_map(fn
      {:attribute, _, :behaviour, b} ->
        try do
          b.behaviour_info(:callbacks)
        rescue
          _ -> []
        catch
          _, _ -> []
        end

      _other ->
        []
    end)
    |> MapSet.new()
  end

  defp rewrite_via_abstract_code(beam_path, module, forms, funcs_to_remove, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    new_forms =
      Enum.flat_map(forms, fn
        {:function, _line, name, arity, _clauses} = form ->
          if MapSet.member?(funcs_to_remove, {module, name, arity}), do: [], else: [form]

        # Remove the function from the -export() attribute so the compiler
        # doesn't complain about an exported function with no definition.
        {:attribute, line, :export, exports} ->
          filtered =
            Enum.reject(exports, fn {f, a} -> MapSet.member?(funcs_to_remove, {module, f, a}) end)

          [{:attribute, line, :export, filtered}]

        # Strip the typespec for removed functions too.
        {:attribute, _line, :spec, {{name, arity}, _spec}} = form ->
          if MapSet.member?(funcs_to_remove, {module, name, arity}), do: [], else: [form]

        form ->
          [form]
      end)

    compile_opts =
      [:return_errors, :return_warnings] ++
        if Keyword.get(opts, :keep_debug_info, false), do: [:debug_info], else: []

    case :compile.forms(new_forms, compile_opts) do
      {:ok, ^module, binary, _warnings} ->
        if not dry_run do
          File.write!(beam_path, binary)
        end

        :ok

      {:error, errors, _warnings} ->
        {:error, {:compile_error, format_errors(errors)}}
    end
  end

  # Returns all MFAs defined in the BEAM (prefers abstract_code for private fns).
  defp functions_for(beam_path) do
    {:ok, module, forms} = get_abstract_code(beam_path)

    Enum.flat_map(forms, fn
      {:function, _line, name, arity, _clauses} -> [{module, name, arity}]
      _other -> []
    end)
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

  defp get_abstract_code(beam_path) do
    with {:ok, module, {:raw_abstract_v1, forms}} <- get_beam_chunk(beam_path, :abstract_code) do
      {:ok, module, forms}
    end
  end

  defp get_beam_chunk(beam_path, chunk) do
    beam_path
    |> String.to_charlist()
    |> :beam_lib.chunks([chunk])
    |> case do
      {:ok, {module, [{^chunk, value}]}} ->
        {:ok, module, value}

      error ->
        error
    end
  end
end
