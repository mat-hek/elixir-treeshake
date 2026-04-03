defmodule Treeshake.Utils.CallGraph do
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

  alias Treeshake.Utils.BFS
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

    BFS.traverse(starting_points, %{}, fn {m, f, a} = mfa, graph ->
      {calls, potential_modules} =
        with %{^m => %{public_functions: pub}} <- module_index,
             %{calls: c, potential_modules: pm} <- Map.get(pub, {f, a}) do
          {c, pm}
        else
          _ -> {[], []}
        end

      known_potential_modules =
        potential_modules
        |> Enum.filter(&Map.has_key?(module_index, &1))

      behaviour_calls =
        Enum.flat_map(known_potential_modules, fn mod ->
          module_index[mod]
          |> Map.get(:behaviours, [])
          |> Enum.flat_map(fn beh ->
            case module_index[beh] do
              %{callbacks: cbs} -> Enum.map(cbs, fn {cb_f, cb_a} -> {mod, cb_f, cb_a} end)
              _ -> []
            end
          end)
        end)

      # When a module atom appears as a literal (e.g. passed to Supervisor.start_link),
      # the supervisor will call child_spec/1 on it at runtime — add that edge explicitly.
      child_spec_calls =
        known_potential_modules
        |> Enum.filter(fn mod ->
          Map.has_key?(module_index[mod].public_functions, {:child_spec, 1})
        end)
        |> Enum.map(fn mod -> {mod, :child_spec, 1} end)

      all_calls = Enum.uniq(calls ++ behaviour_calls ++ child_spec_calls)
      neighbors = Enum.filter(all_calls, &known_public?(module_index, &1))
      {neighbors, Map.put(graph, mfa, all_calls)}
    end)
  end

  # ---- private ----

  defp build_module_index(beam_paths) do
    Enum.reduce(beam_paths, %{}, fn path, acc ->
      case BeamReader.read(path) do
        {:ok, module_info} ->
          analysis = BeamAnalyzer.analyze(module_info)
          Map.put(acc, analysis.module, analysis)

        :error ->
          acc
      end
    end)
  end

  defp known_public?(module_index, {module, name, arity}) do
    case Map.get(module_index, module) do
      %{public_functions: pub} -> Map.has_key?(pub, {name, arity})
      nil -> false
    end
  end
end
