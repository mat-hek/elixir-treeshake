defmodule Treeshake.DialyzerCaller do
  @otp_apps [:erts, :kernel, :stdlib]

  def get_call_graph(beam_dirs, opts \\ []) do
    plt_path = build_plt(beam_dirs, opts)
    build_call_graph(plt_path, beam_dirs, opts)
  end

  defp build_plt(beam_dirs, opts) do
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    build_base_plt = Keyword.get(opts, :build_base_plt, true)
    # base_plt = Path.join(tmp_dir, "base.plt")
    base_plt = "/Users/matheksm/treeshake/dialyzer_tmp/base.plt"

    if build_base_plt do
      take_lock(base_plt <> ".lock", fn ->
        unless File.exists?(base_plt) do
          # Build base plt
          run_dialyzer(~w|
          --build_plt
          --output_plt #{base_plt}
          --apps #{Enum.join(@otp_apps, " ")}
          -pa #{elixir_ebin()}
          -r #{elixir_ebin()}
          |)
        end
      end)
    end

    # Build project plt
    File.mkdir_p!(Path.join(tmp_dir, "proj_plt"))
    cache_ref = Keyword.get(opts, :cache_ref, random_str())
    plt_path = Path.join(tmp_dir, "proj_plt/proj_plt_#{cache_ref}.plt")

    unless File.exists?(plt_path) do
      run_dialyzer(
        ~w|
        --output_plt #{plt_path}
        -pa #{elixir_ebin()}
        | ++
          Enum.flat_map(beam_dirs, &~w|-r #{&1}|) ++
          if(build_base_plt, do: ~w|--add_to_plt --plt #{base_plt}|, else: ~w|--build_plt|)
      )
    end

    plt_path
  end

  defp build_call_graph(plt_path, beam_dirs, opts) do
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "callgraph"))
    cache_ref = Keyword.get(opts, :cache_ref, random_str())
    callgraph_path = Path.join(tmp_dir, "callgraph/callgraph_#{cache_ref}.dot")

    unless File.exists?(callgraph_path) do
      run_dialyzer(~w|
      --dump_callgraph #{callgraph_path}
      --plt #{plt_path}
      -pa #{elixir_ebin()}
    | ++ Enum.flat_map(beam_dirs, &~w|-r #{&1}|))
    end

    File.read!(callgraph_path)
    |> Treeshake.Utils.DotParser.parse_content()
  end

  defp elixir_ebin() do
    elixir_dir = :code.lib_dir(:elixir)

    with {:error, reason} <- elixir_dir do
      raise "Couldn't locate Elixir stdlib, reason: #{reason}"
    end

    Path.join(elixir_dir, "ebin")
  end

  defp run_dialyzer(args, cmd_args \\ []) do
    case System.cmd(
           "dialyzer",
           args,
           [stderr_to_stdout: true] ++ cmd_args
         ) do
      {_output, code} when code in 0..2 ->
        # 0 = success, 1 = warnings, 2 = unknown functions — all acceptable
        # for PLT build/update; the file is written regardless.
        :ok

      {output, code} ->
        raise "Unexpected dialyzer result: #{code}, output: \n#{output}"
    end
  end

  defp random_str() do
    datetime = DateTime.utc_now() |> DateTime.to_iso8601()
    random = Enum.random(0..100_000) |> to_string() |> String.pad_leading(6, "0")
    datetime <> "-" <> random
  end

  def take_lock(path, fun) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)
        fun.()
        File.rm(path)

      {:error, :eexist} ->
        # File already existed
        Stream.interval(100)
        |> Enum.find(fn _i -> not File.exists?(path) end)

        false

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create", path: path
    end
  end
end
