defmodule Treeshake do
  @stdlib_apps [:erts, :kernel, :stdlib, :compiler, :elixir, :logger]
  @non_treeshakable_apps [:erts, :stdlib, :kernel, :logger]
  @force_remove_modules [
    Code.Formatter,
    :prim_inet,
    :erl_lint,
    # :erl_parse,
    :qlc,
    :qlc_pt,
    :dets_v9,
    :dets,
    :sofs,
    :erl_tar,
    # :epp,
    # :erl_scan,
    :file_sorter,
    # :global,
    :disk_log,
    # :net_kernel,
    :zip,
    # :inet_db,
    :edlin_expand,
    :dets_utils
  ]

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

    beams =
      config.opts.ebin_files
      |> filter_ext(".beam")
      |> Enum.reject(&(beam_module(&1) in @force_remove_modules))

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

    unless Map.has_key?(opts, :output_dir) or opts.dry_run do
      raise "Missing required option: output_dir"
    end

    stats = Treeshake.Shaker.shake(opts, call_graph, module_index)

    unless opts.dry_run do
      helper_path = :code.which(:treeshake_helper)
      File.cp!(helper_path, Path.join(opts.output_dir, Path.basename(helper_path)))
    end

    stats
  end

  defp parse_opts(opts) do
    opts = Keyword.put_new(opts, :dry_run, false)
    default_non_treeshakable = non_treeshakable_stdlib_modules()

    opts =
      Keyword.update(
        opts,
        :non_treeshakable_modules,
        default_non_treeshakable,
        &(&1 ++ default_non_treeshakable)
      )

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
        if Keyword.get(opts, :copy_stdlibs, true), do: get_stdlibs(), else: []

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
    ebin = build_dir |> Path.join("**/ebin/*") |> Path.wildcard()
    Enum.uniq_by(consolidated ++ ebin, &Path.basename/1)
  end

  defp get_stdlibs() do
    Enum.flat_map(@stdlib_apps, fn app ->
      app |> :code.lib_dir() |> Path.join("ebin/*") |> Path.wildcard()
    end)
  end

  defp non_treeshakable_stdlib_modules() do
    @non_treeshakable_apps
    |> Enum.flat_map(fn app ->
      app |> :code.lib_dir() |> Path.join("ebin/*.beam") |> Path.wildcard()
    end)
    |> Enum.map(&beam_module/1)
    |> Enum.reject(&(&1 in @force_remove_modules))
  end

  defp beam_module(beam_path) do
    beam_path |> Path.basename(".beam") |> String.to_atom()
  end

  defp filter_ext(paths, ext) do
    Enum.filter(paths, fn path -> Path.extname(path) == ext end)
  end
end
