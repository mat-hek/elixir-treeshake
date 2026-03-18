defmodule Mix.Tasks.Treeshake do
  use Mix.Task

  @shortdoc "Remove unreachable modules and functions from compiled BEAM files"

  @moduledoc """
  Dead-code eliminator for compiled Elixir projects.

  Builds a call graph with dialyzer (falling back to `:xref`) to determine
  which modules and functions are reachable from the application's entry
  points, then removes the unreachable ones from the compiled output.

  ## Usage

      mix treeshake [options] <project_path>

  ## Options

    * `--entry MODULE:fun/arity` — Root entry-point MFA (may be repeated).
      Auto-detected from `.app` file(s) when omitted.
    * `--output DIR` — Write modified BEAMs here instead of in place.
    * `--plt PATH` — Use this existing PLT instead of building one. Skips
      PLT generation entirely.
    * `--no-plt` — Skip PLT generation and use `:xref` for the call graph.
    * `--env ENV` — Mix env whose `_build` dir to analyse (default: `prod`).
    * `--dry-run` — Report what would be removed; don't touch files.
    * `--no-debug-info` — Strip `debug_info` from rewritten BEAM files.
    * `--remove-exports` — Also remove unreachable exported functions.
    * `--verbose` — Print each removed item.

  ## Entry-point format

      Elixir modules: MyApp.Application:start/2
      Erlang modules: gen_server:init/1

  ## Examples

      # Dry-run with verbose output
      mix treeshake --dry-run --verbose /path/to/my_app

      # Shake into a separate directory (original files untouched)
      mix treeshake --output /tmp/my_app_shaken /path/to/my_app

      # Use an existing PLT for faster/richer analysis
      mix treeshake --plt ~/.mix/plts/erlang-26.plt /path/to/my_app

      # Explicit entry point
      mix treeshake --entry MyApp.Supervisor:start_link/1 /path/to/my_app
  """

  @switches [
    entry: [:string, :keep],
    output: :string,
    plt: :string,
    no_plt: :boolean,
    env: :string,
    dry_run: :boolean,
    no_debug_info: :boolean,
    remove_exports: :boolean,
    verbose: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {_parsed, [], []} ->
        Mix.raise("missing required argument: project_path\n\n#{usage()}")

      {_, _, [{bad, _} | _]} ->
        Mix.raise("unknown option: #{bad}\n\n#{usage()}")

      {parsed, [project_path | _], []} ->
        execute(project_path, parsed)
    end
  end

  # ---- execution ----

  defp execute(project_path, parsed) do
    dry_run = Keyword.get(parsed, :dry_run, false)

    if dry_run do
      Mix.shell().info("[DRY RUN — no files will be modified]\n")
    end

    with {:ok, opts} <- build_opts(parsed),
         {:ok, opts} <- maybe_build_plt(project_path, opts) do
      case Treeshake.run(project_path, opts) do
        {:ok, stats} ->
          print_summary(stats, dry_run)

        {:error, {:no_build_dir, msg}} ->
          Mix.raise(msg)

        {:error, :no_entry_points_found} ->
          Mix.raise("""
          Could not detect entry points from .app file(s).
          Specify them explicitly:
            mix treeshake --entry MyApp.Application:start/2 #{project_path}
          """)

        {:error, reason} ->
          Mix.raise("tree-shaking failed: #{inspect(reason)}")
      end
    else
      {:error, reason} -> Mix.raise("treeshake failed: #{inspect(reason)}")
    end
  end

  defp print_summary(stats, dry_run) do
    verb = if dry_run, do: "Would remove", else: "Removed"
    shell = Mix.shell()

    shell.info("\n=== Tree-shaking summary ===")

    if stats.modules_removed != [] do
      shell.info("#{verb} #{length(stats.modules_removed)} whole module(s):")
      Enum.each(stats.modules_removed, &shell.info("  #{inspect(&1)}"))
    end

    total_fns = length(stats.functions_removed)

    if total_fns > 0 do
      shell.info(
        "#{verb} #{total_fns} function(s) from #{length(stats.modules_rewritten)} module(s)"
      )
    end

    if stats.skipped_no_debug_info != [] do
      shell.info(
        "\nNote: #{length(stats.skipped_no_debug_info)} module(s) had dead functions " <>
          "but could not be rewritten (no debug_info chunk):"
      )

      Enum.each(stats.skipped_no_debug_info, &shell.info("  #{inspect(&1)}"))
      shell.info("  Recompile with debug_info to enable function-level removal.")
    end

    if stats.modules_removed == [] and total_fns == 0 do
      shell.info("Nothing to remove — all code is reachable from the entry points.")
    end
  end

  # ---- PLT ----

  # Builds or updates the PLT unless the caller passed --plt or --no-plt.
  # On success, injects the resolved plt_path into opts so CallGraph picks it up.
  defp maybe_build_plt(project_path, opts) do
    cond do
      Keyword.get(opts, :no_plt, false) ->
        {:ok, opts}

      Keyword.get(opts, :plt_path) != nil ->
        {:ok, opts}

      not dialyzer_available?() ->
        Mix.shell().info("dialyzer not found — skipping PLT, falling back to :xref")
        {:ok, opts}

      true ->
        with {:ok, project} <- Treeshake.Project.load(project_path, opts),
             {:ok, plt_path} <- Treeshake.Plt.ensure(project, opts) do
          {:ok, Keyword.put(opts, :plt_path, plt_path)}
        end
    end
  end

  defp dialyzer_available?, do: System.find_executable("dialyzer") != nil

  # ---- option helpers ----

  defp build_opts(parsed) do
    with {:ok, entries} <- parse_all_entry_points(Keyword.get_values(parsed, :entry)) do
      {:ok,
       [
         entry_points: entries,
         output_dir: Keyword.get(parsed, :output),
         plt_path: Keyword.get(parsed, :plt),
         no_plt: Keyword.get(parsed, :no_plt, false),
         mix_env: Keyword.get(parsed, :env, "prod"),
         dry_run: Keyword.get(parsed, :dry_run, false),
         keep_debug_info: not Keyword.get(parsed, :no_debug_info, false),
         remove_exports: Keyword.get(parsed, :remove_exports, false),
         verbose: Keyword.get(parsed, :verbose, false)
       ]}
    end
  end

  defp parse_all_entry_points([]), do: {:ok, []}

  defp parse_all_entry_points(entries) do
    results = Enum.map(entries, &parse_entry_point/1)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, msg} -> {:error, msg}
      nil -> {:ok, Enum.map(results, fn {:ok, mfa} -> mfa end)}
    end
  end

  defp parse_entry_point(str) do
    with [mod_str, rest] <- String.split(str, ":", parts: 2),
         [fun_str, arity_str] <- String.split(rest, "/", parts: 2),
         {arity, ""} <- Integer.parse(arity_str) do
      {:ok, {to_module_atom(mod_str), String.to_atom(fun_str), arity}}
    else
      _ ->
        {:error, "invalid entry point \"#{str}\" — expected format: Module:function/arity"}
    end
  end

  defp to_module_atom(str) do
    cond do
      String.starts_with?(str, "Elixir.") -> String.to_atom(str)
      String.match?(str, ~r/^[A-Z]/) -> String.to_atom("Elixir." <> str)
      true -> String.to_atom(str)
    end
  end

  defp usage do
    "Run `mix help treeshake` for usage information."
  end
end
