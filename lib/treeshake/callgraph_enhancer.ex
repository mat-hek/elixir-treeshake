defmodule Treeshake.CallgraphEnhancer do
  @moduledoc """
  Enhances the inter-module call graph produced by Dialyzer by adding edges
  based on hardcoded MFA tuples found in the abstract code of project beams.

  ## Edge addition rule

  For every function {M1, F1, A1} in the scanned beams, an edge
  {M1, F1, A1} -> {M2, F2, A2} is added when a 3-tuple
  `{M2, F2, A2}` appears literally in the body of {M1, F1, A1} **or** in the
  body of any non-exported (private) function transitively called by
  {M1, F1, A1} within the same module.

  A2 may be:
    * an integer literal — used directly as the arity, or
    * a literal-length list — arity is inferred from the list's length.

  ## child_spec edges

  For every module M in the scanned beams that exports `child_spec/1`,
  `enhance/2` adds an edge {M1, F1, A1} -> {M, :child_spec, 1} for every
  function whose body contains the atom `M` hardcoded.  This models the fact
  that a supervisor referencing a child module by atom may call its
  `child_spec/1` at runtime.

  ## Behaviour edges

  For every module M in the scanned beams that implements a behaviour,
  `enhance/2` adds an edge {M1, F1, A1} -> {M, Cb, CbArity} for every
  function whose body contains the atom `M` hardcoded, and for every callback
  `{Cb, CbArity}` declared by the implemented behaviour(s).  This models the
  fact that a caller passing `M` as a module argument may invoke any of its
  behaviour callbacks via dynamic dispatch.
  """

  @type mfa_tuple :: {atom(), atom(), non_neg_integer()}
  @type graph :: %{mfa_tuple() => [mfa_tuple()]}

  @doc """
  Enhances `call_graph` using abstract-code analysis of `beam_files`.

  Returns the enhanced call graph.
  """
  @spec enhance(graph(), [Path.t()]) :: graph()
  def enhance(call_graph, beam_files) do
    # First pass: collect module metadata needed for edge synthesis.
    {child_spec_modules, behaviour_callbacks, module_behaviours} =
      Enum.reduce(
        beam_files,
        {MapSet.new(), %{}, %{}},
        fn beam_path, {cs_acc, cb_acc, beh_acc} ->
          case get_forms(beam_path) do
            {:ok, module, forms} ->
              exports = collect_exports(forms)

              cs_acc =
                if MapSet.member?(exports, {:child_spec, 1}),
                  do: MapSet.put(cs_acc, module),
                  else: cs_acc

              # Callbacks defined by this module (it is a behaviour).
              callbacks =
                Enum.flat_map(forms, fn
                  {:attribute, _, :callback, {{name, arity}, _}} -> [{name, arity}]
                  _ -> []
                end)

              # Behaviours this module declares it implements.
              behaviours =
                Enum.flat_map(forms, fn
                  {:attribute, _, :behaviour, beh} -> [beh]
                  _ -> []
                end)

              cb_acc = if callbacks != [], do: Map.put(cb_acc, module, callbacks), else: cb_acc

              beh_acc =
                if behaviours != [], do: Map.put(beh_acc, module, behaviours), else: beh_acc

              {cs_acc, cb_acc, beh_acc}

            _ ->
              {cs_acc, cb_acc, beh_acc}
          end
        end
      )

    # Derive: impl_module => [{cb_name, cb_arity}] for all known callbacks.
    impl_module_callbacks =
      module_behaviours
      |> Map.new(fn {impl_mod, behaviours} ->
        callbacks = Enum.flat_map(behaviours, &Map.get(behaviour_callbacks, &1, []))
        {impl_mod, callbacks}
      end)
      |> Map.filter(fn {_mod, cbs} -> cbs != [] end)

    # Second pass: collect edges.
    new_edges =
      Enum.flat_map(beam_files, fn beam_path ->
        case get_forms(beam_path) do
          {:ok, module, forms} ->
            exports = collect_exports(forms)
            local_cg = build_local_call_graph(forms)

            Enum.flat_map(forms, fn
              {:function, _, name, arity, clauses} ->
                source = {module, name, arity}
                priv_closure = compute_private_closure(name, arity, exports, local_cg)

                # Collect bodies of this function and its private callee closure
                all_bodies =
                  [clauses] ++
                    Enum.map(priv_closure, fn {fn_name, fn_arity} ->
                      get_function_body(forms, fn_name, fn_arity)
                    end)

                mfa_edges =
                  all_bodies
                  |> collect_mfa_tuples()
                  |> Enum.map(fn target -> {source, target} end)

                child_spec_edges =
                  child_spec_modules
                  |> Enum.filter(fn m -> contains_atom?(all_bodies, m) end)
                  |> Enum.map(fn m -> {source, {m, :child_spec, 1}} end)

                behaviour_edges =
                  impl_module_callbacks
                  |> Enum.filter(fn {m, _cbs} -> contains_atom?(all_bodies, m) end)
                  |> Enum.flat_map(fn {m, cbs} ->
                    Enum.map(cbs, fn {cb_name, cb_arity} ->
                      {source, {m, cb_name, cb_arity}}
                    end)
                  end)

                mfa_edges ++ child_spec_edges ++ behaviour_edges

              _ ->
                []
            end)

          _ ->
            []
        end
      end)

    Enum.reduce(new_edges, call_graph, fn {source, target}, cg ->
      Map.update(cg, source, [target], fn existing ->
        if target in existing, do: existing, else: [target | existing]
      end)
    end)
  end

  # ---- private helpers ----

  defp get_forms(beam_path) do
    case :beam_lib.chunks(String.to_charlist(beam_path), [:abstract_code]) do
      {:ok, {module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
        {:ok, module, forms}

      _ ->
        :error
    end
  end

  defp collect_exports(forms) do
    Enum.reduce(forms, MapSet.new(), fn
      {:attribute, _, :export, exports}, acc -> MapSet.union(acc, MapSet.new(exports))
      _, acc -> acc
    end)
  end

  # Builds a map {name, arity} => MapSet of directly-called {name, arity} in same module.
  defp build_local_call_graph(forms) do
    Map.new(
      Enum.flat_map(forms, fn
        {:function, _, name, arity, clauses} ->
          [{{name, arity}, collect_local_calls(clauses) |> MapSet.new()}]

        _ ->
          []
      end)
    )
  end

  defp collect_local_calls(forms) when is_list(forms) do
    Enum.flat_map(forms, &collect_local_calls/1)
  end

  defp collect_local_calls({:call, _, {:atom, _, name}, args}) do
    [{name, length(args)}] ++ collect_local_calls(args)
  end

  defp collect_local_calls({:fun, _, {:function, name, arity}}) do
    [{name, arity}]
  end

  defp collect_local_calls({:call, _, _remote_or_var, args}) do
    collect_local_calls(args)
  end

  defp collect_local_calls(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> collect_local_calls()
  end

  defp collect_local_calls(_), do: []

  # Returns the set of non-exported {name, arity} pairs transitively reachable
  # from {name, arity} via local calls (BFS, private functions only).
  defp compute_private_closure(name, arity, exports, local_cg) do
    direct_privates =
      Map.get(local_cg, {name, arity}, MapSet.new())
      |> MapSet.filter(fn fa -> not MapSet.member?(exports, fa) end)

    bfs_expand(direct_privates, direct_privates, exports, local_cg)
  end

  defp bfs_expand(frontier, visited, exports, local_cg) do
    new_nodes =
      frontier
      |> Enum.flat_map(fn fa ->
        Map.get(local_cg, fa, MapSet.new())
        |> MapSet.filter(fn target ->
          not MapSet.member?(exports, target) and not MapSet.member?(visited, target)
        end)
        |> MapSet.to_list()
      end)
      |> MapSet.new()

    if MapSet.size(new_nodes) == 0 do
      visited
    else
      bfs_expand(new_nodes, MapSet.union(visited, new_nodes), exports, local_cg)
    end
  end

  defp get_function_body(forms, name, arity) do
    case Enum.find(forms, fn
           {:function, _, ^name, ^arity, _} -> true
           _ -> false
         end) do
      {:function, _, _, _, clauses} -> clauses
      nil -> []
    end
  end

  # Recursively collect all {M, F, A} tuples from abstract-code forms.
  # Works regardless of how deeply the MFA tuple is nested inside other tuples,
  # lists, maps, case expressions, or any other hard-coded data structure.
  defp collect_mfa_tuples(forms) when is_list(forms) do
    Enum.flat_map(forms, &collect_mfa_tuples/1)
  end

  # Tuple literal in abstract code: check if it's an MFA, then recurse into children.
  defp collect_mfa_tuples({:tuple, _, children}) do
    own = List.wrap(extract_mfa(children))
    own ++ collect_mfa_tuples(children)
  end

  # Any other Erlang abstract-code node (map, call, case, clause, cons, …) is
  # also an Erlang tuple.  Recurse through all its elements so we never miss an
  # MFA tuple nested inside e.g. a map literal or a function call argument list.
  defp collect_mfa_tuples(form) when is_tuple(form) do
    form |> Tuple.to_list() |> collect_mfa_tuples()
  end

  defp collect_mfa_tuples(_), do: []

  # Helper: extract a single MFA from the children list of a tuple form, or nil.
  # {atom, atom, integer} — classic {Module, :fun, arity}
  defp extract_mfa([{:atom, _, m}, {:atom, _, f}, {:integer, _, a}])
       when is_atom(m) and is_atom(f) and is_integer(a) and a >= 0,
       do: {m, f, a}

  # {atom, atom, list} — e.g. {Module, :start_link, [arg]}; arity = list length
  defp extract_mfa([{:atom, _, m}, {:atom, _, f}, list_form])
       when is_atom(m) and is_atom(f) do
    case count_literal_list(list_form) do
      {:ok, arity} -> {m, f, arity}
      :error -> nil
    end
  end

  defp extract_mfa(_), do: nil

  defp contains_atom?(forms, atom) when is_list(forms) do
    Enum.any?(forms, &contains_atom?(&1, atom))
  end

  defp contains_atom?({:atom, _, a}, atom), do: a == atom

  defp contains_atom?(tuple, atom) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> contains_atom?(atom)
  end

  defp contains_atom?(_, _), do: false

  # Returns {:ok, length} if `form` represents a literal-length proper list,
  # :error otherwise.  The list elements may be arbitrary expressions.
  defp count_literal_list({nil, _}), do: {:ok, 0}

  defp count_literal_list({:cons, _, _head, tail}) do
    case count_literal_list(tail) do
      {:ok, n} -> {:ok, n + 1}
      :error -> :error
    end
  end

  defp count_literal_list(_), do: :error
end
