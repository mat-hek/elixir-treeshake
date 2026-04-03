defmodule Treeshake.Utils.BFS do
  @moduledoc """
  Generic breadth-first traversal over a set of nodes.

  Provides a single `traverse/4` function that accepts an initial accumulator
  and a visitor callback, making it suitable for both pure reachability
  (accumulate visited nodes) and graph-building (accumulate edges) use cases.
  """

  @doc """
  Performs a breadth-first traversal starting from `seeds`.

  For each unvisited node the `visit` function is called with `(node, acc)`.
  It must return `{neighbors, acc}` where `neighbors` is the list of nodes to
  enqueue next (already-visited ones are skipped automatically).

  Returns the final accumulator after all reachable nodes have been visited.
  """
  @spec traverse(Enumerable.t(), acc, (node, acc -> {[node], acc})) :: acc
        when node: term(), acc: term()
  def traverse(seeds, acc, visit) do
    queue = seeds |> Enum.to_list() |> :queue.from_list()
    visited = seeds |> Enum.into(MapSet.new())
    do_traverse(queue, visited, acc, visit)
  end

  defp do_traverse({[], []}, _visited, acc, _visit), do: acc

  defp do_traverse(queue, visited, acc, visit) do
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

    do_traverse(queue, visited, acc, visit)
  end
end
