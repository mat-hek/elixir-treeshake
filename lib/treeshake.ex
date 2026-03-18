defmodule Treeshake do
  @moduledoc """
  Tree-shaking for Elixir projects.

  Analyzes compiled BEAM files using dialyzer's call graph to determine which
  modules and functions are reachable from the application's entry points, then
  removes unreachable ones from the compiled output.

  ## Usage

      Treeshake.run("/path/to/my_app", dry_run: true, verbose: true)

  ## Options

    * `:entry_points` - List of `{module, function, arity}` tuples to use as
      roots. Auto-detected from `.app` files if omitted.
    * `:output_dir` - Directory to write modified BEAM files into. If `nil`,
      files are modified in place.
    * `:plt_path` - Path to a dialyzer PLT file.
    * `:mix_env` - Mix environment string, e.g. `"prod"` (default).
    * `:dry_run` - When `true`, report what would be removed without modifying
      any files.
    * `:keep_debug_info` - Preserve `debug_info` chunk in rewritten BEAMs
      (default `true`).
    * `:remove_exports` - Also remove unreachable exported functions
      (default `false`).
    * `:verbose` - Print progress information (default `false`).
  """

  alias Treeshake.{BeamRewriter, CallGraph, Plt, Project, Reachability}

  @type mfa_tuple :: {atom(), atom(), non_neg_integer()}
  @type opts :: keyword()

  @spec run(String.t(), opts()) :: {:ok, map()} | {:error, term()}
  def run(project_path, opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)

    with {:ok, project} <- Project.load(project_path, opts) do
      if verbose do
        IO.puts("Found #{length(project.all_beam_files)} BEAM files across #{length(project.beam_dirs)} ebin dirs")
      end

      opts =
        if Keyword.has_key?(opts, :plt_path) do
          opts
        else
          case Plt.ensure(project, opts) do
            {:ok, plt_path} -> Keyword.put(opts, :plt_path, plt_path)
            {:error, _} -> opts
          end
        end

      with {:ok, call_graph} <- CallGraph.build(project, opts) do
        if verbose do
          edge_count = call_graph |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
          IO.puts("Call graph: #{map_size(call_graph)} nodes, #{edge_count} edges")
        end

        with {:ok, entry_points} <- resolve_entry_points(project, opts),
             {:ok, reachable} <- Reachability.compute(call_graph, entry_points) do
          if verbose do
            all_mfas = CallGraph.all_mfas(project)
            dead = Reachability.compute_dead(all_mfas, reachable)
            IO.puts("Entry points:    #{MapSet.size(entry_points)}")
            IO.puts("Reachable MFAs:  #{MapSet.size(reachable.mfas)}")
            IO.puts("Reachable mods:  #{MapSet.size(reachable.modules)}")
            IO.puts("Dead modules:    #{length(dead.dead_modules)}")
            IO.puts("Dead functions:  #{length(dead.dead_mfas)}")
          end

          stats = BeamRewriter.rewrite(project, reachable, opts)
          {:ok, stats}
        end
      end
    end
  end

  defp resolve_entry_points(project, opts) do
    case Keyword.get(opts, :entry_points, []) do
      [] -> Project.detect_entry_points(project)
      entries -> {:ok, MapSet.new(entries)}
    end
  end
end
