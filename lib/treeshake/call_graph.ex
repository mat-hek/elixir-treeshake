defmodule Treeshake.CallGraph do
  @moduledoc """
  Builds a call graph for an Elixir/Erlang project.

  ## Primary backend — dialyzer

  Runs `dialyzer --dump_callgraph <tmp_file>` against the project's BEAM directories.
  Dialyzer writes a DOT file where each edge represents a direct call between
  two MFAs. The DOT file is then parsed by `Treeshake.DotParser`.

  Dialyzer produces a more accurate call graph than xref because it incorporates
  type information: it can tell that certain call branches are unreachable due
  to type constraints. This means the reachable set computed from a dialyzer
  call graph may be smaller (fewer false positives) than one from xref.

  ## Fallback backend — :xref

  If dialyzer is not installed or fails to produce output, the tool falls back
  to Erlang's built-in `:xref` cross-reference analyser. `:xref` performs a
  purely syntactic analysis but is always available when Erlang/OTP is present.

  ## Return value

  Both backends return `{:ok, graph}` where `graph` is a map:

      %{{module, function, arity} => [{module, function, arity}]}

  Each key is a caller MFA and its value is the list of MFAs it directly calls.
  """

  require Logger

  alias Treeshake.{DotParser, Project}

  # :xref lives in the :tools OTP app; suppress compile-time undefined warnings
  # since the module is available at runtime via extra_applications.
  @compile {:no_warn_undefined, :xref}

  @type mfa_tuple :: {atom(), atom(), non_neg_integer()}
  @type graph :: %{mfa_tuple() => [mfa_tuple()]}

  @doc """
  Build the call graph for `project`, trying dialyzer first then falling back
  to `:xref`.
  """
  @spec build(Project.t(), keyword()) :: {:ok, graph()} | {:error, term()}
  def build(project, opts \\ []) do
    case build_dialyzer(project, opts) do
      {:ok, graph} ->
        {:ok, graph}

      {:error, reason} ->
        Logger.warning(
          "Dialyzer call graph unavailable (#{inspect(reason)}); " <>
            "falling back to :xref (syntactic analysis only)"
        )

        build_xref(project)
    end
  end

  @doc """
  Return all MFAs defined across every BEAM file in the project.
  """
  @spec all_mfas(Project.t()) :: [mfa_tuple()]
  def all_mfas(project) do
    Enum.flat_map(project.all_beam_files, fn beam_path ->
      module = Project.module_from_beam(beam_path)
      charlist = String.to_charlist(beam_path)

      case :beam_lib.chunks(charlist, [:exports]) do
        {:ok, {^module, [{:exports, exports}]}} ->
          Enum.map(exports, fn {f, a} -> {module, f, a} end)

        _ ->
          []
      end
    end)
  end

  # ---- dialyzer backend ----

  defp build_dialyzer(project, opts) do
    unless dialyzer_available?() do
      {:error, :dialyzer_not_found}
    else
      dot_file = Path.join(System.tmp_dir!(), "treeshake_cg_#{:os.getpid()}.dot")

      try do
        args = dialyzer_args(project, dot_file, opts)

        case System.cmd("dialyzer", args, stderr_to_stdout: true, cd: project.path) do
          {_output, exit_code} when exit_code in [0, 1, 2] ->
            # 0 = no warnings, 1 = warnings found, 2 = error — dialyzer commonly
            # exits with 2 for missing PLT but may still write the call graph.
            if File.exists?(dot_file) do
              DotParser.parse_file(dot_file)
            else
              {:error, {:no_dot_file, exit_code}}
            end

          {output, code} ->
            {:error, {:dialyzer_failed, code, output}}
        end
      after
        File.rm(dot_file)
      end
    end
  end

  defp dialyzer_args(project, dot_file, opts) do
    plt_args =
      case Keyword.get(opts, :plt_path) do
        nil -> ["--no_check_plt"]
        plt -> ["--plt", plt]
      end

    # -pa makes elixir_erl available so dialyzer can decode elixir_v1 debug_info.
    pa_args =
      case Treeshake.Plt.elixir_ebin() do
        nil -> []
        ebin -> ["-pa", ebin]
      end

    dir_args = Enum.flat_map(project.beam_dirs, &["-r", &1])

    ["--dump_callgraph", dot_file, "--quiet"] ++ plt_args ++ pa_args ++ dir_args
  end

  defp dialyzer_available?() do
    System.find_executable("dialyzer") != nil
  end

  # ---- :xref fallback ----

  defp build_xref(project) do
    # Use a unique server name to avoid collisions when called concurrently.
    server = :"treeshake_xref_#{:os.getpid()}"

    try do
      :xref.start(server, [])

      Enum.each(project.beam_dirs, fn dir ->
        :xref.add_directory(server, String.to_charlist(dir), [{:warnings, false}])
      end)

      case :xref.q(server, ~c"E") do
        {:ok, edges} ->
          graph =
            Enum.reduce(edges, %{}, fn {{fm, ff, fa}, {tm, tf, ta}}, acc ->
              from = {fm, ff, fa}
              to = {tm, tf, ta}
              Map.update(acc, from, [to], &[to | &1])
            end)

          {:ok, graph}

        {:error, _module, reason} ->
          {:error, {:xref_query_failed, reason}}
      end
    after
      :xref.stop(server)
    end
  end
end
