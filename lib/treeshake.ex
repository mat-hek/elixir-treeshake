defmodule Treeshake do
  @built_in_apps [:erts, :kernel, :stdlib, :elixir, :logger]

  def run(project_path, opts \\ []) do
    mix_env = "prod"
    path = Path.expand(project_path)
    build_dir = Path.join([path, "_build", mix_env])

    if not File.dir?(build_dir) do
      raise "Run `MIX_ENV=#{mix_env} mix compile` first. Expected: #{build_dir}"
    end

    beam_dirs = find_beam_dirs(build_dir)
    run_beams(beam_dirs, opts)
  end

  def run_beams(beam_dirs, opts \\ []) do
    tmp_dir = Keyword.get(opts, :tmp_dir, "/Users/matheksm/treeshake/dialyzer_tmp")

    beam_dirs =
      beam_dirs ++ if Keyword.get(opts, :copy_stdlibs, true), do: copy_stdlibs(tmp_dir), else: []

    all_beams = wildcard_dirs(beam_dirs, "*.beam")

    entry_points = detect_entry_points(beam_dirs) ++ Keyword.get(opts, :extra_entry_points, [])

    if entry_points == [] do
      raise "No entry points found"
    end

    call_graph =
      Treeshake.DialyzerCaller.get_call_graph(beam_dirs,
        cache_ref: Keyword.get(opts, :cache_ref),
        tmp_dir: tmp_dir,
        build_base_plt: Keyword.get(opts, :build_base_plt, true)
      )

    reachable = Treeshake.Reachability.find_reachable(call_graph, entry_points)
    stats = Treeshake.BeamRewriter.rewrite(all_beams, reachable, opts)
    {:ok, stats}
  end

  defp detect_entry_points(beam_dirs) do
    app_files = wildcard_dirs(beam_dirs, "*.app")

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

  defp wildcard_dirs(dirs, wildcard) do
    Enum.flat_map(dirs, fn dir -> Path.join(dir, wildcard) |> Path.wildcard() end)
  end

  defp copy_stdlibs(tmp_dir) do
    stdlibs_dir = Path.join(tmp_dir, "stdlibs")
    File.mkdir_p!(stdlibs_dir)

    for app <- @built_in_apps do
      dest = Path.join(stdlibs_dir, "#{app}")
      File.cp_r!(:code.lib_dir(app, :ebin), dest)
      dest
    end
  end
end
