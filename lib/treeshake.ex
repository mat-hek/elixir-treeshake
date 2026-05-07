defmodule Treeshake do
  @stdlib_apps [:erts, :kernel, :stdlib, :compiler, :elixir, :logger]

  def run(opts) do
    opts
    |> config()
    |> build_module_index()
    |> build_call_graph()
    |> shake()
  end

  def config(opts) do
    opts = parse_opts(opts)
    %{opts: opts, module_index: nil, call_graph: nil}
  end

  def build_module_index(config) do
    IO.puts("Building module index")

    beams = filter_ext(config.opts.ebin_files, ".beam")
    %{config | module_index: Treeshake.ModuleIndex.build(beams)}
  end

  def build_call_graph(%{opts: opts, module_index: module_index} = config)
      when module_index != nil do
    IO.puts("Creating call graph")

    app_files = filter_ext(opts.ebin_files, ".app")
    entry_points = detect_entry_points(app_files) ++ Map.get(opts, :extra_entry_points, [])

    if entry_points == [] do
      raise "No entry points found"
    end

    %{config | call_graph: Treeshake.CallGraph.create(module_index, entry_points)}
  end

  def shake(%{opts: opts, module_index: module_index, call_graph: call_graph})
      when module_index != nil and call_graph != nil do
    IO.puts("Shaking")

    stats = Treeshake.Shaker.shake(opts, call_graph, module_index)

    # FIXME handle case when output_dir is nil
    if opts[:output_dir] != nil and not opts[:dry_run] do
      helper_path = :code.which(:treeshake_helper)
      File.cp!(helper_path, Path.join(opts.output_dir, Path.basename(helper_path)))
    end

    stats
  end

  defp parse_opts(opts) do
    default_tmp_dir =
      "/Users/matheksm/treeshake/dialyzer_tmp"
      |> Path.join(Keyword.get(opts, :tmp_subdir, random_str()))

    opts = Keyword.put_new(opts, :dry_run, false)
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
      Keyword.get(opts, :ebin_files, []) ++
        project_ebin_files ++
        if Keyword.get(opts, :copy_stdlibs, true), do: copy_stdlibs(tmp_dir), else: []

    ebin_files = Enum.uniq_by(ebin_files, &Path.basename/1)
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
    consolidated = build_dir |> Path.join("**/consolidated/*") |> Path.wildcard()
    # consolidated = []
    ebin = build_dir |> Path.join("**/ebin/*") |> Path.wildcard()
    Enum.uniq_by(consolidated ++ ebin, &Path.basename/1)
  end

  defp copy_stdlibs(tmp_dir) do
    stdlibs_dir = Path.join(tmp_dir, "stdlibs")
    File.mkdir_p!(stdlibs_dir)

    Enum.flat_map(@stdlib_apps, fn app ->
      dest = Path.join(stdlibs_dir, "#{app}")
      File.rm_rf!(dest)
      File.cp_r!(:code.lib_dir(app, :ebin), dest)
      Path.wildcard(Path.join(dest, "*"))
    end)
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
