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

  # Always-protected function signatures: Elixir/Erlang internals that must
  # remain in every module or the VM / compiler will reject the BEAM.
  @protected_fns MapSet.new([
                   {:__info__, 1},
                   {:module_info, 0},
                   {:module_info, 1},
                   {:child_spec, 1}
                 ])

  @doc """
  Walk all BEAM files in `project`, remove dead code according to `reachable`,
  and return a statistics map.
  """
  @spec rewrite(Project.t(), map(), map()) :: stats()
  def rewrite(all_beams, reachable, opts \\ %{}) do
    dry_run = Map.get(opts, :dry_run, false)
    output_dir = Map.get(opts, :output_dir)

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

    reachable = enrich_with_protocol_impls(all_beams, reachable)

    empty_stats = %{
      modules_removed: [],
      beams_removed: [],
      functions_removed: [],
      modules_rewritten: [],
      skipped_no_debug_info: []
    }

    Enum.reduce(all_beams, empty_stats, fn beam_path, stats ->
      module = beam_path |> Path.basename(".beam") |> String.to_atom()

      if module_app(module) in [:erts, :kernel, :stdlib, :logger] do
        stats
      else
        if MapSet.member?(reachable.modules, module) do
          process_live_module(beam_path, module, reachable, stats, opts)
        else
          remove_dead_module(beam_path, module, stats, opts)
        end
      end
    end)
  end

  defp remove_functions(beam_path, funcs_to_remove, opts) do
    {:ok, module, forms} = get_abstract_code(beam_path)
    rewrite_via_abstract_code(beam_path, module, forms, funcs_to_remove, opts)
  end

  defp remove_dead_module(beam_path, module, stats, opts) do
    verbose_log(opts, "  [-] #{module} (whole module)")

    unless Map.get(opts, :dry_run, false) do
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

  # If a protocol module is reachable, all its implementations must be kept too
  # because protocol dispatch is dynamic and Dialyzer won't capture those edges.
  defp enrich_with_protocol_impls(all_beams, reachable) do
    Enum.reduce(all_beams, reachable, fn beam_path, acc ->
      with {:ok, module, forms} <- get_abstract_code(beam_path),
           protocol when is_atom(protocol) <- find_impl_protocol(forms),
           true <- MapSet.member?(acc.modules, protocol) do
        impl_mfas =
          forms
          |> Enum.flat_map(fn
            {:function, _, name, arity, _} -> [{module, name, arity}]
            _ -> []
          end)
          |> MapSet.new()

        %{acc | mfas: MapSet.union(acc.mfas, impl_mfas), modules: MapSet.put(acc.modules, module)}
      else
        _ -> acc
      end
    end)
  end

  defp find_impl_protocol(forms) do
    Enum.find_value(forms, fn
      {:function, _, :__impl__, 1, clauses} ->
        Enum.find_value(clauses, fn
          {:clause, _, [{:atom, _, :protocol}], [], [{:atom, _, protocol}]} -> protocol
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  # Returns the list of dead (unreachable) MFAs in a module.
  defp find_dead_functions(beam_path, reachable) do
    # Protocol modules have tightly-coupled infrastructure (__protocol__/1,
    # impl_for/1, impl_for!/1, struct_impl_for/1) that cannot be stripped
    # individually — the module would fail to recompile if any are removed.
    if protocol_module?(beam_path) do
      []
    else
      {:ok, module, forms} = get_abstract_code(beam_path)
      protected = behaviour_callbacks_from_forms(forms)

      # Seed: functions reachable from the inter-module call graph or always kept.
      initially_live =
        Enum.flat_map(forms, fn
          {:function, _, name, arity, _} ->
            if MapSet.member?(reachable.mfas, {module, name, arity}) or
                 MapSet.member?(@protected_fns, {name, arity}) or
                 MapSet.member?(protected, {name, arity}),
               do: [{name, arity}],
               else: []

          _ ->
            []
        end)
        |> MapSet.new()

      # Extend to the full intra-module closure: any function called (directly
      # or transitively) from a live function must also be kept. Dialyzer's
      # inter-module call graph does not capture these local edges.
      call_graph = build_local_call_graph(forms)
      live = compute_intra_module_closure(initially_live, call_graph)

      Enum.flat_map(forms, fn
        {:function, _, name, arity, _} -> [{module, name, arity}]
        _ -> []
      end)
      |> Enum.reject(fn {_m, f, a} -> MapSet.member?(live, {f, a}) end)
    end
  end

  # Builds a map of {name, arity} => MapSet of {name, arity} local calls.
  defp build_local_call_graph(forms) do
    Map.new(
      Enum.flat_map(forms, fn
        {:function, _, name, arity, clauses} ->
          [{{name, arity}, clauses |> collect_local_calls() |> MapSet.new()}]

        _ ->
          []
      end)
    )
  end

  # Recursively collect all local (non-remote) call targets from abstract code.
  defp collect_local_calls(forms) when is_list(forms) do
    Enum.flat_map(forms, &collect_local_calls/1)
  end

  defp collect_local_calls({:call, _, {:atom, _, name}, args}) do
    [{name, length(args)}] ++ collect_local_calls(args)
  end

  # Capture of a local function reference: &foo/1 compiles to {:fun, _, {:function, name, arity}}
  defp collect_local_calls({:fun, _, {:function, name, arity}}) do
    [{name, arity}]
  end

  defp collect_local_calls({:call, _, _fun_or_remote, args}) do
    collect_local_calls(args)
  end

  defp collect_local_calls(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> collect_local_calls()
  end

  defp collect_local_calls(_), do: []

  # Fixed-point expansion: keeps adding functions reachable from the live set.
  defp compute_intra_module_closure(live, call_graph) do
    new_live =
      Enum.reduce(live, live, fn fa, acc ->
        MapSet.union(acc, Map.get(call_graph, fa, MapSet.new()))
      end)

    if MapSet.equal?(new_live, live),
      do: live,
      else: compute_intra_module_closure(new_live, call_graph)
  end

  defp module_app(module) do
    case :application.get_application(module) do
      {:ok, app} -> app
      _other -> nil
    end
  end

  defp protocol_module?(beam_path) do
    case get_abstract_code(beam_path) do
      {:ok, _module, forms} ->
        Enum.any?(forms, &match?({:function, _, :__protocol__, 1, _}, &1))

      _ ->
        false
    end
  end

  # Returns a MapSet of {fun, arity} pairs that are required callbacks of any
  # behaviour declared in the module's abstract code.
  defp behaviour_callbacks_from_forms(forms) do
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
    dry_run = Map.get(opts, :dry_run, false)

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

        # Remove dead functions from -compile({inline, [...]}) to avoid
        # bad_inline lint errors when the inlined function no longer exists.
        {:attribute, line, :compile, value} ->
          [{:attribute, line, :compile, filter_inline(value, module, funcs_to_remove)}]

        form ->
          [form]
      end)

    compile_opts =
      [:return_errors, :return_warnings] ++
        if Map.get(opts, :keep_debug_info, false), do: [:debug_info], else: []

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

  # Strips removed functions from -compile({inline, [...]}) values.
  # Handles both `{:inline, [...]}` and `[inline: [...], ...]` forms.
  defp filter_inline({:inline, inlines}, module, funcs_to_remove) do
    {:inline,
     Enum.reject(inlines, fn {f, a} -> MapSet.member?(funcs_to_remove, {module, f, a}) end)}
  end

  defp filter_inline(opts, module, funcs_to_remove) when is_list(opts) do
    Enum.map(opts, fn
      {:inline, inlines} ->
        {:inline,
         Enum.reject(inlines, fn {f, a} -> MapSet.member?(funcs_to_remove, {module, f, a}) end)}

      other ->
        other
    end)
  end

  defp filter_inline(other, _module, _funcs_to_remove), do: other

  defp verbose_log(opts, msg) do
    if Map.get(opts, :verbose, false), do: IO.puts(msg)
  end

  defp format_errors(errors) do
    IO.inspect(errors, pretty: true)
    # Enum.flat_map(errors, fn {_file, errs} ->
    #   Enum.map(errs, fn {line, mod, desc} ->
    #     "line #{line}: #{mod.format_error(desc)}"
    #   end)
    # end)
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
