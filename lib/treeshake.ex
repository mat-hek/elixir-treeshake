defmodule Treeshake do
  def run(project_path, opts \\ []) do
    mix_env = "prod"
    path = Path.expand(project_path)
    build_dir = Path.join([path, "_build", mix_env])
    beam_dirs = find_beam_dirs(build_dir)
    all_beams = Enum.flat_map(beam_dirs, &Path.wildcard(Path.join(&1, "*.beam")))

    if not File.dir?(build_dir) do
      raise "Run `MIX_ENV=#{mix_env} mix compile` first. Expected: #{build_dir}"
    end

    entry_points = detect_entry_points(build_dir)

    if entry_points == [] do
      raise "No entry points found"
    end

    call_graph = Treeshake.DialyzerCaller.get_call_graph(beam_dirs)

    reachable = Treeshake.Reachability.find_reachable(call_graph, entry_points)
    stats = Treeshake.BeamRewriter.rewrite(all_beams, reachable, opts)
    {:ok, stats}
  end

  defp detect_entry_points(build_dir) do
    app_files =
      build_dir
      |> Path.join("**/ebin/*.app")
      |> Path.wildcard()

    Enum.flat_map(app_files, fn app_file ->
      with {:ok, [{:application, _name, attrs}]} <-
             :file.consult(String.to_charlist(app_file)),
           {mod, _args} <- Keyword.get(attrs, :mod) do
        [{mod, :start, 2}]
      else
        _not_found -> []
      end
    end)
  end

  defp find_beam_dirs(build_dir) do
    build_dir
    |> Path.join("**/ebin")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end
end
