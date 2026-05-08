defmodule Treeshake.CallGraph do
  @moduledoc """
  Builds a call graph from a collection of BEAM files, seeded by a set of
  entry-point MFA tuples.

  Each BEAM file is read with `Treeshake.Utils.BeamParser` and its
  public-function call sites are resolved with `Treeshake.Utils.BeamAnalyzer`
  (private functions are flattened into their public callers).  A BFS is then
  performed from the given entry points, collecting only functions that are
  reachable and are known public functions from the provided BEAM files.

  The resulting graph is compatible with `Treeshake.Reachability`.
  """

  alias Treeshake.Utils.Graph
  @type mfa_tuple :: {atom(), atom(), non_neg_integer()}
  @type graph :: %{mfa_tuple() => [mfa_tuple()]}

  @protocol_built_in_types [
    Tuple,
    Atom,
    List,
    BitString,
    Integer,
    Float,
    Function,
    PID,
    Map,
    Port,
    Reference,
    Any
  ]

  @doc """
  Builds a call graph from the given BEAM files, seeded by `keep`.

  Reads every BEAM file, analyses its public-function call sites, and performs
  a breadth-first traversal from `keep`.

  Returns `%{ {M, F, A} => [{M2, F2, A2}, ...] }` where each key is a
  reachable MFA and its value is the full list of MFAs it calls (including
  calls to external modules not present in the provided BEAM list — those
  will appear in values but not as keys).

  BEAM files that cannot be read (no debug info, corrupt, etc.) are skipped.
  """
  @spec create([Path.t()], [mfa_tuple()]) :: graph()
  def create(module_index, keep) do
    protocols_impls =
      Enum.flat_map(module_index, fn
        {module, %{protocol_impl: {protocol, type}}} ->
          Map.get_lazy(module_index, protocol, fn ->
            raise "Module #{module} implements unknown protocol #{protocol}"
          end)
          |> unless do
            raise "Module #{module} implements #{protocol} as if it was a protocol, but it's not"
          end

          [%{protocol: protocol, type: type, impl: module}]

        _non_protocol ->
          []
      end)

    protocols_impls_by_protocol = Enum.group_by(protocols_impls, & &1.protocol)
    protocols_impls_by_type = Enum.group_by(protocols_impls, & &1.type)

    keep =
      Enum.flat_map(keep, fn
        {m, f, a} ->
          [{m, f, a}]

        m when is_atom(m) ->
          Map.fetch!(module_index, m).public_functions
          |> Enum.map(fn {{f, a}, _info} -> {m, f, a} end)
      end)

    bfs_acc = %{
      graph: %{},
      protocol_calls: MapSet.new(),
      referenced_modules: MapSet.new(@protocol_built_in_types)
    }

    Graph.bfs(keep, bfs_acc, fn {m, f, a} = mfa, acc ->
      %{
        graph: graph,
        protocol_calls: acc_protocol_calls,
        referenced_modules: acc_referenced_modules
      } = acc

      function_info = get_in(module_index[m].public_functions[{f, a}])
      function_info = function_info || %{calls: [], potential_modules: []}

      referenced_modules_info =
        if {f, a} in [impl_for: 1, impl_for!: 1] do
          []
        else
          Enum.flat_map(
            function_info.potential_modules,
            &case module_index[&1] do
              nil -> []
              info -> [info]
            end
          )
        end

      acc_referenced_modules =
        MapSet.union(
          acc_referenced_modules,
          MapSet.new(referenced_modules_info, & &1.module)
        )

      behaviour_calls =
        referenced_modules_info
        |> Enum.flat_map(fn info ->
          Enum.map(info.behaviour_impls, &{info.module, &1})
        end)
        |> Enum.flat_map(fn {module, behaviour} ->
          case module_index[behaviour] do
            %{abstraction: {:behaviour, callbacks}} ->
              callbacks

            nil ->
              raise "Module #{module} implements unknown behaviour #{behaviour}"

            _info ->
              raise "Module #{module} implements #{behaviour} as if it was a behaviour, but it's not"
          end
          |> Enum.map(fn {f, a} -> {module, f, a} end)
        end)

      # When a module atom appears as a literal (e.g. passed to Supervisor.start_link),
      # the supervisor will call child_spec/1 on it at runtime — add that edge explicitly.
      child_spec_calls =
        referenced_modules_info
        |> Enum.filter(fn info -> Map.has_key?(info.public_functions, {:child_spec, 1}) end)
        |> Enum.map(fn info -> {info.module, :child_spec, 1} end)

      all_calls =
        (function_info.calls ++ behaviour_calls ++ child_spec_calls)
        |> Enum.reject(&(&1 == mfa))

      protocol_edges_from_calls =
        all_calls
        |> Enum.filter(fn {cm, cf, ca} ->
          case get_in(module_index[cm].abstraction) do
            {:protocol, funs} -> {cf, ca} in funs
            _other -> false
          end
        end)
        |> Enum.flat_map(fn {cm, cf, ca} ->
          Map.fetch!(protocols_impls_by_protocol, cm)
          |> Enum.filter(&(&1.type in acc_referenced_modules))
          |> Enum.map(&{{&1.protocol, cf, ca}, {&1.impl, cf, ca}})
        end)

      acc_protocol_calls =
        MapSet.union(acc_protocol_calls, MapSet.new(protocol_edges_from_calls, &key/1))

      protocol_edges_from_modules =
        referenced_modules_info
        |> Enum.flat_map(fn info -> Map.get(protocols_impls_by_type, info.module, []) end)
        |> Enum.flat_map(fn %{protocol: protocol, impl: impl} ->
          Map.fetch!(module_index, impl).public_functions
          |> Map.keys()
          |> Enum.filter(fn {f, a} -> {protocol, f, a} in acc_protocol_calls end)
          |> Enum.map(fn {f, a} -> {{protocol, f, a}, {impl, f, a}} end)
        end)

      protocol_entries =
        Enum.group_by(
          protocol_edges_from_modules ++ protocol_edges_from_calls,
          &key/1,
          &value/1
        )

      graph =
        graph
        |> merge_graph([{mfa, all_calls}])
        |> merge_graph(protocol_entries)

      acc = %{
        graph: graph,
        protocol_calls: acc_protocol_calls,
        referenced_modules: acc_referenced_modules
      }

      {all_calls ++ Enum.flat_map(protocol_entries, &value/1), acc}
    end).graph
  end

  defp merge_graph(graph, to_merge) do
    Enum.reduce(to_merge, graph, fn {k, v}, acc ->
      case Map.fetch(acc, k) do
        {:ok, v2} -> v ++ v2
        :error -> v
      end
      |> Enum.sort()
      |> Enum.dedup()
      |> then(&Map.put(acc, k, &1))
    end)
  end

  defp key({k, _v}), do: k
  defp value({_k, v}), do: v
end
