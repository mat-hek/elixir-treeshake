defmodule Treeshake.Reachability do
  @moduledoc """
  Computes the set of reachable MFAs given a call graph and a set of entry
  points using breadth-first search.

  A function is *reachable* if it is an entry point or if it is transitively
  called by a reachable function. A module is *reachable* if at least one of
  its functions is reachable.
  """

  @type mfa_tuple :: {atom(), atom(), non_neg_integer()}
  @type graph :: %{mfa_tuple() => [mfa_tuple()]}
  @type result :: %{mfas: MapSet.t(mfa_tuple()), modules: MapSet.t(atom())}

  @doc """
  Compute all MFAs (and their modules) reachable from the given entry points
  by following `call_graph`.

  Returns `{:ok, %{mfas: reachable_mfa_set, modules: reachable_module_set}}`.
  """
  @spec find_reachable(graph(), Enumerable.t(mfa_tuple())) :: result()
  def find_reachable(call_graph, entry_points) do
    seeds = Enum.to_list(entry_points)
    visited = bfs(call_graph, :queue.from_list(seeds), MapSet.new(seeds))

    modules =
      visited
      |> MapSet.to_list()
      |> Enum.map(fn {m, _f, _a} -> m end)
      |> MapSet.new()

    %{mfas: visited, modules: modules}
  end

  @doc """
  Given the full list of MFAs defined in the project and the reachability
  result from `compute/2`, return the dead (unreachable) MFAs and modules.
  """
  @spec find_dead([mfa_tuple()], result()) ::
          %{dead_mfas: [mfa_tuple()], dead_modules: [atom()]}
  def find_dead(all_mfas, reachable) do
    all_modules = all_mfas |> Enum.map(fn {m, _f, _a} -> m end) |> Enum.uniq()

    dead_mfas = Enum.reject(all_mfas, &MapSet.member?(reachable.mfas, &1))
    dead_modules = Enum.reject(all_modules, &MapSet.member?(reachable.modules, &1))

    %{dead_mfas: dead_mfas, dead_modules: dead_modules}
  end

  # ---- private ----

  defp bfs(_graph, {[], []}, visited), do: visited

  defp bfs(graph, queue, visited) do
    {{:value, node}, queue} = :queue.out(queue)

    {queue, visited} =
      graph
      |> Map.get(node, [])
      |> Enum.reduce({queue, visited}, fn callee, {q, vis} ->
        if MapSet.member?(vis, callee) do
          {q, vis}
        else
          {:queue.in(callee, q), MapSet.put(vis, callee)}
        end
      end)

    bfs(graph, queue, visited)
  end
end
