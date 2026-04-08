defmodule Treeshake.CallGraph do
  @moduledoc """
  Builds a call graph from a collection of BEAM files, seeded by a set of
  entry-point MFA tuples.

  Each BEAM file is read with `Treeshake.Utils.BeamReader` and its
  public-function call sites are resolved with `Treeshake.Utils.BeamAnalyzer`
  (private functions are flattened into their public callers).  A BFS is then
  performed from the given starting points, collecting only functions that are
  reachable and are known public functions from the provided BEAM files.

  The resulting graph is compatible with `Treeshake.Reachability`.
  """

  alias Treeshake.Utils.Graph
  alias Treeshake.Utils.BeamReader
  alias Treeshake.Utils.BeamAnalyzer

  @type mfa_tuple :: {atom(), atom(), non_neg_integer()}
  @type graph :: %{mfa_tuple() => [mfa_tuple()]}

  @doc """
  Builds a call graph from the given BEAM files, seeded by `starting_points`.

  Reads every BEAM file, analyses its public-function call sites, and performs
  a breadth-first traversal from `starting_points`.

  Returns `%{ {M, F, A} => [{M2, F2, A2}, ...] }` where each key is a
  reachable MFA and its value is the full list of MFAs it calls (including
  calls to external modules not present in the provided BEAM list — those
  will appear in values but not as keys).

  BEAM files that cannot be read (no debug info, corrupt, etc.) are skipped.
  """
  @spec create([Path.t()], [mfa_tuple()]) :: graph()
  def create(beam_paths, starting_points) do
    module_index = build_module_index(beam_paths)

    Graph.bfs(starting_points, %{}, fn {m, f, a} = mfa, graph ->
      {calls, potential_modules} =
        with %{^m => %{public_functions: pub}} <- module_index,
             %{calls: c, potential_modules: pm} <- Map.get(pub, {f, a}) do
          {c, pm}
        else
          _ -> {[], []}
        end

      referenced_modules_info =
        Enum.flat_map(
          potential_modules,
          &case module_index[&1] do
            nil -> []
            info -> [info]
          end
        )

      behaviour_calls =
        referenced_modules_info
        |> Enum.flat_map(fn info ->
          Enum.map(info.behaviour_impls ++ Keyword.keys(info.protocol_impls), &{info.module, &1})
        end)
        |> Enum.flat_map(fn {module, abstraction} ->
          case module_index[abstraction] do
            %{abstraction: {_type, callbacks}} -> callbacks
            nil -> raise "Protocol or behaviour #{abstraction} not found"
            _info -> raise "Expected #{abstraction} to be a protocol or behaviour, but it's not"
          end
          |> Enum.map(fn {f, a} -> {module, f, a} end)
        end)

      # When a module atom appears as a literal (e.g. passed to Supervisor.start_link),
      # the supervisor will call child_spec/1 on it at runtime — add that edge explicitly.
      child_spec_calls =
        referenced_modules_info
        |> Enum.filter(fn info -> Map.has_key?(info.public_functions, {:child_spec, 1}) end)
        |> Enum.map(fn info -> {info.module, :child_spec, 1} end)

      all_calls = Enum.uniq(calls ++ behaviour_calls ++ child_spec_calls)
      {all_calls, Map.put(graph, mfa, all_calls)}
    end)
  end

  def explain(graph, mfa, max_len \\ 8)

  def explain(graph, m, max_len) when is_atom(m) do
    explain(graph, {m, nil, nil}, max_len)
  end

  def explain(graph, {m, f}, max_len) do
    explain(graph, {m, f, nil}, max_len)
  end

  def explain(graph, {m, f, a}, max_len) do
    starting_points =
      Enum.flat_map(graph, fn {k, v} ->
        Enum.filter([k | v], fn {m1, f1, a1} ->
          m in [m1, nil] and f in [f1, nil] and a in [a1, nil]
        end)
      end)
      |> Enum.uniq()

    Graph.reachable_paths(graph, starting_points, :up, max_len: max_len)
  end

  defp build_module_index(beam_paths) do
    Map.new(beam_paths, fn path ->
      analysis = path |> BeamReader.read!() |> BeamAnalyzer.analyze()
      {analysis.module, analysis}
    end)
  end
end
