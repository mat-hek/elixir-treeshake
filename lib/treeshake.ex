defmodule Treeshake do
  @stdlib_apps [:erts, :kernel, :stdlib, :compiler, :elixir, :logger]
  @non_treeshakable_apps [:erts, :kernel, :stdlib, :logger]

  def run(opts \\ []) do
    opts = parse_opts(opts)

    non_treeshakable_modules =
      Map.get(opts, :non_treeshakable_modules, [])
      |> MapSet.new(&to_string/1)
      |> MapSet.union(non_treeshakable_stdlib_modules())

    beams = filter_ext(opts.ebin_files, ".beam")

    treeshakable_beams =
      Enum.reject(beams, fn path -> Path.basename(path, ".beam") in non_treeshakable_modules end)

    call_graph = do_build_call_graph(opts)

    IO.puts("rewriting")
    stats = Treeshake.BeamRewriter.rewrite(treeshakable_beams, call_graph, opts)

    stats
  end

  def build_call_graph(opts \\ []) do
    opts = parse_opts(opts)
    do_build_call_graph(opts)
  end

  defp do_build_call_graph(opts) do
    beams = filter_ext(opts.ebin_files, ".beam")

    app_files = filter_ext(opts.ebin_files, ".app")
    entry_points = detect_entry_points(app_files) ++ Map.get(opts, :extra_entry_points, [])

    if entry_points == [] do
      raise "No entry points found"
    end

    IO.puts("creating call graph")
    Treeshake.Utils.CallGraph.create(beams, entry_points)
  end

  defp parse_opts(opts) do
    default_tmp_dir =
      "/Users/matheksm/treeshake/dialyzer_tmp"
      |> Path.join(Keyword.get(opts, :tmp_subdir, random_str()))

    opts = Keyword.put_new(opts, :tmp_dir, default_tmp_dir)
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    File.mkdir_p!(tmp_dir)

    {project, opts} = Keyword.pop(opts, :project)

    project_ebin_files =
      case project do
        nil ->
          []

        project_path ->
          mix_env = "prod"
          path = Path.expand(project_path)
          build_dir = Path.join([path, "_build", mix_env])

          if not File.dir?(build_dir) do
            raise "Run `MIX_ENV=#{mix_env} mix compile` first. Expected: #{build_dir}"
          end

          find_ebin_files(build_dir)
      end

    ebin_files =
      project_ebin_files ++
        Keyword.get(opts, :ebin_files, []) ++
        if Keyword.get(opts, :copy_stdlibs, true), do: copy_stdlibs(tmp_dir), else: []

    opts = Keyword.put(opts, :ebin_files, ebin_files)

    Map.new(opts)
  end

  def detect_entry_points(app_files) do
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

  defp find_ebin_files(build_dir) do
    build_dir
    |> Path.join("**/ebin/*")
    |> Path.wildcard()
  end

  defp copy_stdlibs(tmp_dir) do
    stdlibs_dir = Path.join(tmp_dir, "stdlibs")
    File.mkdir_p!(stdlibs_dir)

    Enum.flat_map(@stdlib_apps, fn app ->
      dest = Path.join(stdlibs_dir, "#{app}")

      unless File.dir?(dest) do
        File.cp_r!(:code.lib_dir(app, :ebin), dest)
      end

      Path.wildcard(Path.join(dest, "*"))
    end)
  end

  defp non_treeshakable_stdlib_modules() do
    @non_treeshakable_apps
    |> Enum.flat_map(fn app ->
      Path.wildcard(Path.join(:code.lib_dir(app, :ebin), "*.beam"))
    end)
    |> MapSet.new(&Path.basename(&1, ".beam"))
  end

  defp filter_ext(paths, ext) do
    Enum.filter(paths, fn path -> Path.extname(path) == ext end)
  end

  defp random_str() do
    datetime = DateTime.utc_now() |> DateTime.to_iso8601()
    random = Enum.random(0..100_000) |> to_string() |> String.pad_leading(6, "0")
    datetime <> "-" <> random
  end
end
