defmodule Treeshake.Project do
  @moduledoc """
  Represents an Elixir/Mix project and provides utilities for discovering its
  structure: BEAM directories, `.app` files, and application entry points.
  """

  defstruct [:path, :name, :beam_dirs, :app_files, :all_beam_files, :mix_env]

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          beam_dirs: [String.t()],
          app_files: [String.t()],
          all_beam_files: [String.t()],
          mix_env: String.t()
        }

  @doc """
  Load project information from the given path.

  Expects `_build/<mix_env>` to exist, so `mix compile` must have been run first.
  """
  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(project_path, opts \\ []) do
    mix_env = Keyword.get(opts, :mix_env, "prod")
    path = Path.expand(project_path)
    build_dir = Path.join([path, "_build", mix_env])

    if not File.dir?(build_dir) do
      {:error, {:no_build_dir, "Run `MIX_ENV=#{mix_env} mix compile` first. Expected: #{build_dir}"}}
    else
      beam_dirs = find_beam_dirs(build_dir)
      app_files = find_app_files(build_dir)
      all_beam_files = Enum.flat_map(beam_dirs, &Path.wildcard(Path.join(&1, "*.beam")))

      project = %__MODULE__{
        path: path,
        name: Path.basename(path),
        beam_dirs: beam_dirs,
        app_files: app_files,
        all_beam_files: all_beam_files,
        mix_env: mix_env
      }

      {:ok, project}
    end
  end

  @doc """
  Detect entry points by inspecting the project's `.app` files.

  Reads the `mod:` key from each `.app` file (Erlang application resource file)
  and returns the corresponding `start/2` MFA as the root entry point.
  """
  @spec detect_entry_points(t()) ::
          {:ok, MapSet.t({atom(), atom(), non_neg_integer()})} | {:error, :no_entry_points_found}
  def detect_entry_points(%__MODULE__{app_files: app_files}) do
    entries =
      Enum.flat_map(app_files, fn app_file ->
        case :file.consult(String.to_charlist(app_file)) do
          {:ok, [{:application, _name, attrs}]} ->
            attrs |> Keyword.get(:mod) |> entry_from_mod()

          _ ->
            []
        end
      end)

    case entries do
      [] -> {:error, :no_entry_points_found}
      _ -> {:ok, MapSet.new(entries)}
    end
  end

  @doc """
  Returns the module atom for a BEAM file path.

      iex> Treeshake.Project.module_from_beam("/path/to/Elixir.Foo.beam")
      :"Elixir.Foo"
  """
  @spec module_from_beam(String.t()) :: atom()
  def module_from_beam(beam_path) do
    beam_path |> Path.basename(".beam") |> String.to_atom()
  end

  # ---- private ----

  defp entry_from_mod({mod, _args}), do: [{mod, :start, 2}]
  defp entry_from_mod(nil), do: []

  defp find_beam_dirs(build_dir) do
    build_dir
    |> Path.join("**/ebin")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  defp find_app_files(build_dir) do
    build_dir
    |> Path.join("**/ebin/*.app")
    |> Path.wildcard()
  end
end
