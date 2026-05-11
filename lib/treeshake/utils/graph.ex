defmodule Treeshake.Utils.Graph do
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
        [Enum.reverse(path)]

      ns ->
        Enum.flat_map(ns, &do_paths(graph, &1, direction, path, visited, max_len))
    end
  end

  @spec to_dot(%{node => [node]}, keyword()) :: String.t()
        when node: term()
  def to_dot(graph, _opts \\ []) do
    lines =
      Enum.flat_map(graph, fn {from, tos} ->
        from_label = node_label(from)

        case tos do
          [] ->
            ["  #{inspect(from_label)}"]

          _ ->
            Enum.map(tos, fn to ->
              "  #{inspect(from_label)} -> #{inspect(node_label(to))}"
            end)
        end
      end)

    "digraph {\n#{Enum.join(lines, "\n")}\n}\n"
  end

  @spec neighborhood(%{node => [node]}, node, non_neg_integer()) :: %{node => [node]}
        when node: term()
  def neighborhood(graph, node, distance) do
    nodes = do_neighborhood(graph, [{node, 0}], MapSet.new([node]), distance)

    Map.new(nodes, fn n ->
      {n, Map.get(graph, n, []) |> Enum.filter(&MapSet.member?(nodes, &1))}
    end)
  end

  defp do_neighborhood(_graph, [], visited, _distance), do: visited

  defp do_neighborhood(graph, [{node, depth} | queue], visited, distance) do
    {queue, visited} =
      if depth < distance do
        Enum.reduce(Map.get(graph, node, []), {queue, visited}, fn neighbor, {q, vis} ->
          if MapSet.member?(vis, neighbor) do
            {q, vis}
          else
            {q ++ [{neighbor, depth + 1}], MapSet.put(vis, neighbor)}
          end
        end)
      else
        {queue, visited}
      end

    do_neighborhood(graph, queue, visited, distance)
  end

  @spec to_mermaid(%{node => [node]}) :: String.t() when node: term()
  def to_mermaid(graph) do
    ids =
      graph
      |> Enum.flat_map(fn {from, tos} -> [from | tos] end)
      |> Enum.uniq()
      |> Enum.with_index(fn node, i -> {node, "n#{i}"} end)
      |> Map.new()

    nodes = Enum.map(ids, fn {node, id} -> ~s|#{id}["#{node_label(node)}"]| end)

    edges =
      Enum.flat_map(graph, fn
        {from, []} -> [ids[from]]
        {from, tos} -> Enum.map(tos, fn to -> "#{ids[from]} --> #{ids[to]}" end)
      end)

    """
    flowchart TD
    #{Enum.map_join(nodes ++ edges, "\n", &"  #{&1}")}
    """
  end

  @spec reverse(%{node => [node]}) :: %{node => [node]} when node: term()
  def reverse(graph) do
    base = Map.new(graph, fn {k, _} -> {k, []} end)

    Enum.reduce(graph, base, fn {from, tos}, acc ->
      Enum.reduce(tos, acc, fn to, acc ->
        Map.update(acc, to, [from], &(&1 ++ [from]))
      end)
    end)
  end

  def diff(g1, g2) do
    g1
    |> Enum.flat_map(fn {k, v} ->
      v = v -- Map.get(g2, k, [])
      if v == [], do: [], else: [{k, v}]
    end)
    |> Map.new()
  end

  defp node_label({m, f, a}) do
    mod = m |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
    "#{mod}.#{f}/#{a}"
  end

  defp node_label(node), do: inspect(node)

  defp neighbors(graph, node, :down), do: Map.get(graph, node, [])

  defp neighbors(graph, node, :up) do
    Enum.flat_map(graph, fn {k, vs} ->
      if node in vs, do: [k], else: []
    end)
  end

  def nodes(graph) do
    graph |> Enum.flat_map(fn {k, v} -> [k | v] end) |> Enum.sort() |> Enum.dedup()
  end
end
