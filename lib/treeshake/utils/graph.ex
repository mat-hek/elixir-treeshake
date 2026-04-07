defmodule Treeshake.Utils.Graph do
  @moduledoc """
  Generic graph traversal utilities.

  - `bfs/3` — breadth-first traversal, graph-agnostic (neighbors supplied by caller).
  - `dfs/5` — depth-first traversal over a `%{node => [node]}` adjacency map,
    with explicit direction (`:down` follows edges forward, `:up` follows them in reverse).
  """

  @doc """
  Performs a breadth-first traversal starting from `seeds`.

  For each unvisited node the `visit` function is called with `(node, acc)`.
  It must return `{neighbors, acc}` where `neighbors` is the list of nodes to
  enqueue next (already-visited ones are skipped automatically).

  Returns the final accumulator after all reachable nodes have been visited.
  """
  @spec bfs(Enumerable.t(), acc, (node, acc -> {[node], acc})) :: acc
        when node: term(), acc: term()
  def bfs(seeds, acc, visit) do
    queue = seeds |> Enum.to_list() |> :queue.from_list()
    visited = seeds |> Enum.into(MapSet.new())
    do_bfs(queue, visited, acc, visit)
  end

  defp do_bfs({[], []}, _visited, acc, _visit), do: acc

  defp do_bfs(queue, visited, acc, visit) do
    {{:value, node}, queue} = :queue.out(queue)
    {neighbors, acc} = visit.(node, acc)

    {queue, visited} =
      Enum.reduce(neighbors, {queue, visited}, fn neighbor, {q, vis} ->
        if MapSet.member?(vis, neighbor) do
          {q, vis}
        else
          {:queue.in(neighbor, q), MapSet.put(vis, neighbor)}
        end
      end)

    do_bfs(queue, visited, acc, visit)
  end

  @doc """
  Performs a depth-first traversal over an adjacency map `graph` starting from `seeds`.

  `direction` controls which edges are followed:
  - `:down` — forward edges: neighbors are `graph[node]` (callees).
  - `:up`   — reverse edges: neighbors are nodes whose adjacency list contains `node` (callers).

  `visit` is called as `visit.(node, acc)` and must return the updated accumulator.
  Already-visited nodes are skipped.

  Returns the final accumulator after all reachable nodes have been visited.
  """
  @spec dfs(
          %{node => [node]},
          Enumerable.t(),
          :down | :up,
          acc,
          (node, acc -> acc)
        ) :: acc
        when node: term(), acc: term()
  def dfs(graph, seeds, direction, acc, visit) do
    stack = Enum.to_list(seeds)
    visited = MapSet.new(stack)
    do_dfs(graph, stack, visited, acc, visit, direction)
  end

  defp do_dfs(_graph, [], _visited, acc, _visit, _direction), do: acc

  defp do_dfs(graph, [node | stack], visited, acc, visit, direction) do
    acc = visit.(node, acc)
    neighbors = neighbors(graph, node, direction)

    {stack, visited} =
      Enum.reduce(neighbors, {stack, visited}, fn neighbor, {s, vis} ->
        if MapSet.member?(vis, neighbor) do
          {s, vis}
        else
          {[neighbor | s], MapSet.put(vis, neighbor)}
        end
      end)

    do_dfs(graph, stack, visited, acc, visit, direction)
  end

  @doc """
  Returns all paths from `seeds` to leaf nodes reachable in `direction`.

  A leaf is a node with no unvisited neighbors in the chosen direction.
  Cycles are broken per-path (a node already on the current path is not revisited),
  so the same node may appear in multiple returned paths via different routes.

  Returns a list of node lists, each starting at a seed and ending at a leaf.
  """
  @spec reachable_paths(%{node => [node]}, Enumerable.t(), :down | :up, keyword()) :: [[node]]
        when node: term()
  def reachable_paths(graph, seeds, direction, opts \\ []) do
    max_len = Keyword.get(opts, :max_len, :infinity)

    seeds
    |> Enum.to_list()
    |> Enum.flat_map(&do_paths(graph, &1, direction, [], MapSet.new(), max_len))
  end

  defp do_paths(_graph, node, _direction, path, _visited, max_len)
       when max_len != :infinity and length(path) + 1 >= max_len do
    [Enum.reverse([node | path])]
  end

  defp do_paths(graph, node, direction, path, visited, max_len) do
    path = [node | path]
    visited = MapSet.put(visited, node)
    next = neighbors(graph, node, direction) |> Enum.reject(&MapSet.member?(visited, &1))

    case next do
      [] ->
        IO.inspect(path)
        [Enum.reverse(path)]

      ns ->
        Enum.flat_map(ns, &do_paths(graph, &1, direction, path, visited, max_len))
    end
  end

  defp neighbors(graph, node, :down), do: Map.get(graph, node, [])

  defp neighbors(graph, node, :up) do
    Enum.flat_map(graph, fn {k, vs} ->
      if node in vs, do: [k], else: []
    end)
  end
end
