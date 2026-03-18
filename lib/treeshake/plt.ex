defmodule Treeshake.Plt do
  @moduledoc """
  Builds and maintains a Dialyzer PLT (Persistent Lookup Table) for a project.

  The PLT is stored at `_build/<env>/treeshake.plt` and is cached between runs.

  ## Build strategy

  Elixir BEAMs store debug info in the `elixir_v1` format, which dialyzer
  decodes by calling `elixir_erl:debug_info/3`. That function must be present
  in dialyzer's own code path before it can analyse any Elixir BEAM. We
  achieve this with `-pa <elixir_ebin>`.

  The build proceeds in two phases:

  1. **Base PLT** — seed with OTP core apps (`:erts`, `:kernel`, `:stdlib`)
     and Elixir's ebin dir, using `-pa <elixir_ebin>` so that `elixir_erl`
     is available during the build.

  2. **Project PLT** — extend the base PLT with every BEAM directory in the
     project's `_build/<env>` tree.

  On subsequent runs only phase 2 (`--add_to_plt`) is repeated, keeping
  incremental updates fast.
  """

  alias Treeshake.Project

  @otp_apps [:erts, :kernel, :stdlib]

  @doc """
  Ensure a PLT exists and is up-to-date for `project`.

  Returns `{:ok, plt_path}` on success or `{:error, reason}` on failure.
  """
  @spec ensure(Project.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(project, opts \\ []) do
    case Keyword.get(opts, :plt_path) do
      path when is_binary(path) ->
        {:ok, path}

      nil ->
        plt_path = default_plt_path(project)

        if File.exists?(plt_path) do
          update(plt_path, project)
        else
          build(plt_path, project)
        end
    end
  end

  @doc """
  Return the default PLT path for a project (`_build/<env>/treeshake.plt`).
  """
  @spec default_plt_path(Project.t()) :: String.t()
  def default_plt_path(%Project{path: path, mix_env: env}) do
    Path.join([path, "_build", env, "treeshake.plt"])
  end

  @doc """
  Return the path to Elixir's ebin directory, or `nil` if not found.
  """
  @spec elixir_ebin() :: String.t() | nil
  def elixir_ebin do
    case :code.lib_dir(:elixir) do
      {:error, _} -> nil
      dir -> Path.join(List.to_string(dir), "ebin")
    end
  end

  # ---- private ----

  defp build(plt_path, project) do
    shell = Mix.shell()
    shell.info("Building Dialyzer PLT (this may take a while on first run)…")
    shell.info("  → #{plt_path}")

    with :ok <- build_base(plt_path, project),
         :ok <- extend_with_project(plt_path, project) do
      shell.info("PLT built successfully.")
      {:ok, plt_path}
    else
      {:error, reason} ->
        File.rm(plt_path)
        {:error, {:plt_build_failed, reason}}
    end
  end

  # Phase 1: seed the PLT with OTP core apps + Elixir's own BEAMs.
  # The -pa flag loads elixir_erl into dialyzer's VM so it can decode
  # elixir_v1 debug_info in Elixir BEAMs.
  defp build_base(plt_path, project) do
    otp_args = ["--apps" | Enum.map(@otp_apps, &Atom.to_string/1)]

    elixir_args =
      case elixir_ebin() do
        nil -> []
        ebin -> ["-pa", ebin, "-r", ebin]
      end

    args = ["--build_plt", "--output_plt", plt_path, "--quiet"] ++ otp_args ++ elixir_args
    run_dialyzer(args, project)
  end

  # Phase 2: extend the PLT with the project's own BEAM directories.
  defp extend_with_project(plt_path, project) do
    elixir_pa = case elixir_ebin() do
      nil -> []
      ebin -> ["-pa", ebin]
    end

    args =
      ["--add_to_plt", "--plt", plt_path, "--output_plt", plt_path, "--quiet"] ++
        elixir_pa ++
        beam_dir_args(project)

    run_dialyzer(args, project)
  end

  defp update(plt_path, project) do
    Mix.shell().info("Updating Dialyzer PLT…")

    elixir_pa = case elixir_ebin() do
      nil -> []
      ebin -> ["-pa", ebin]
    end

    args =
      ["--add_to_plt", "--plt", plt_path, "--output_plt", plt_path, "--quiet"] ++
        elixir_pa ++
        beam_dir_args(project)

    case run_dialyzer(args, project) do
      :ok ->
        {:ok, plt_path}

      {:error, reason} ->
        Mix.shell().info("PLT update failed (#{inspect(reason)}), rebuilding…")
        File.rm(plt_path)
        build(plt_path, project)
    end
  end

  defp run_dialyzer(args, project) do
    case System.cmd("dialyzer", args, stderr_to_stdout: true, cd: project.path) do
      {_output, code} when code in [0, 1, 2] ->
        # 0 = success, 1 = warnings, 2 = unknown functions — all acceptable
        # for PLT build/update; the file is written regardless.
        :ok

      {output, code} ->
        {:error, {code, String.slice(output, 0, 500)}}
    end
  end

  defp beam_dir_args(project) do
    Enum.flat_map(project.beam_dirs, &["-r", &1])
  end
end
