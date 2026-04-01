defmodule Treeshake.DialyzerCaller do
  # @otp_apps [:erts, :kernel, :stdlib]

  def get_call_graph(beams, opts \\ []) do
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    cache_path = Path.join(tmp_dir, "cache")

    cache =
      beams
      |> Enum.map_join("\n", fn path -> "#{path} #{File.read!(path) |> :erlang.md5()}" end)
      |> :erlang.md5()

    if not Keyword.get(opts, :cached, false) and
         (Keyword.get(opts, :force, false) or File.read(cache_path) != {:ok, cache}) do
      plt_path = build_plt(beams, tmp_dir)
      build_call_graph(plt_path, beams, tmp_dir)
      File.write!(cache_path, cache)
    end

    read_call_graph(tmp_dir)
  end

  defp build_plt(beams, tmp_dir) do
    plt_path = Path.join(tmp_dir, "proj_plt.plt")

    run_dialyzer(~w|
      --build_plt
      --output_plt #{plt_path}
      --plt #{plt_path}
      -pa #{elixir_ebin()}
      #{Enum.join(beams, " ")}
    |)

    plt_path
  end

  defp build_call_graph(plt_path, beams, tmp_dir) do
    callgraph_path = Path.join(tmp_dir, "callgraph.dot")

    run_dialyzer(~w|
      --dump_callgraph #{callgraph_path}
      --plt #{plt_path}
      -pa #{elixir_ebin()}
      #{Enum.join(beams, " ")}
    |)

    callgraph_path
  end

  defp read_call_graph(tmp_dir) do
    callgraph_path = Path.join(tmp_dir, "callgraph.dot")

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
    IO.puts("Calling: dialyzer #{Enum.join(args, " ")}")

    case System.cmd(
           "dialyzer",
           args,
           [stderr_to_stdout: true, into: IO.stream(:stdio, :line)] ++ cmd_args
         ) do
      {_output, code} when code in [0, 2] ->
        # 0 = success, 1 = warnings, 2 = unknown functions — all acceptable
        # for PLT build/update; the file is written regardless.
        :ok

      {output, code} ->
        raise """
        Unexpected dialyzer result: #{code}, output:
        #{if is_binary(output), do: output, else: inspect(output)}
        """
    end
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
