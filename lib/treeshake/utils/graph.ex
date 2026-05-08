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
        [Enum.reverse(path)]

      ns ->
        Enum.flat_map(ns, &do_paths(graph, &1, direction, path, visited, max_len))
    end
  end

  @doc """
  Converts an adjacency map to a DOT-format string suitable for Graphviz.

  Each key in `graph` becomes a node, and each edge `{from, to}` becomes a
  directed arrow. Node labels are derived by calling `to_string/1` on each
  node, so MFA tuples like `{MyApp.Foo, :bar, 2}` render as
  `"Elixir.MyApp.Foo.bar/2"`.

  ## Example

      iex> graph = %{{Foo, :a, 0} => [{Bar, :b, 1}], {Bar, :b, 1} => []}
      iex> Treeshake.Utils.Graph.to_dot(graph)
      ~s(digraph {\\n  "Foo.a/0" -> "Bar.b/1"\\n  "Bar.b/1"\\n}\\n)
  """
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

  @doc """
  Returns the subgraph induced by all nodes reachable from `node` within `distance` hops.

  Follows forward edges. The result contains every node (including `node` itself)
  reachable in at most `distance` steps, with adjacency lists trimmed to only
  include edges whose target is also within the neighborhood.

  ## Example

      iex> Treeshake.Utils.Graph.neighborhood(%{a: [:b, :c], b: [:d], c: [], d: []}, :a, 1)
      %{a: [:b, :c], b: [], c: []}

      iex> Treeshake.Utils.Graph.neighborhood(%{a: [:b, :c], b: [:d], c: [], d: []}, :a, 2)
      %{a: [:b, :c], b: [:d], c: [], d: []}
  """
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

  @doc """
  Converts an adjacency map to a Mermaid flowchart string.

  Each key in `graph` becomes a node, and each edge `{from, to}` becomes a
  directed arrow. Node labels are derived by calling `to_string/1` on each node.
  Special characters in labels (e.g. `/`, `.`, `<`, `>`, `*`) are safe because
  each node is assigned a unique integer ID (e.g. `n0`, `n1`), while the original
  label is preserved in quotes.

  ## Example

      iex> graph = %{{Foo, :a, 0} => [{Bar, :b, 1}], {Bar, :b, 1} => []}
      iex> Treeshake.Utils.Graph.to_mermaid(graph) |> String.starts_with?("flowchart TD")
      true
  """
  @spec to_mermaid(%{node => [node]}) :: String.t() when node: term()
  def to_mermaid(graph) do
    ids =
      graph
      |> Enum.flat_map(fn {from, tos} -> [from | tos] end)
      |> Enum.uniq()
      |> Enum.with_index(fn node, i -> {node, "n#{i}"} end)
      |> Map.new()

    mermaid_node = fn node ->
      ~s(#{ids[node]}["#{node_label(node)}"])
    end

    lines =
      Enum.flat_map(graph, fn
        {from, []} ->
          ["#{mermaid_node.(from)}"]

        {from, tos} ->
          Enum.map(tos, fn to ->
            "#{mermaid_node.(from)} --> #{mermaid_node.(to)}"
          end)
      end)

    """
    flowchart TD
    #{Enum.map_join(lines, "\n", &"  #{&1}")}
    """
  end

  @doc """
  Reverses an adjacency map, swapping edge direction.

  Each edge `from -> to` in `graph` becomes `to -> from` in the result.
  Nodes that appear only as targets (with no outgoing edges) are added as
  keys with empty adjacency lists.

  ## Example

      iex> Treeshake.Utils.Graph.reverse(%{a: [:b, :c], b: [:c], c: []})
      %{a: [], b: [:a], c: [:a, :b]}
  """
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
    mod =
      m
      |> Atom.to_string()
      |> String.replace_prefix("Elixir.", "")

    "#{mod}.#{f}/#{a}"
  end

  defp node_label(node), do: inspect(node)

  defp neighbors(graph, node, :down), do: Map.get(graph, node, [])

  defp neighbors(graph, node, :up) do
    Enum.flat_map(graph, fn {k, vs} ->
      if node in vs, do: [k], else: []
    end)
  end
end
