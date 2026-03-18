defmodule Treeshake.DialyzerCaller do
  @tmp_dir "/Users/matheksm/treeshake/dialyzer_tmp"
  @base_plt Path.join(@tmp_dir, "base.plt")

  @otp_apps [:erts, :kernel, :stdlib]

  def get_call_graph(beams_paths) do
    plt_path = build_plt(beams_paths)
    build_call_graph(plt_path, beams_paths)
  end

  defp build_plt(beams_paths) do
    if not File.exists?(@base_plt) do
      # Build base plt
      run_dialyzer(~w|
        --build_plt
        --output_plt #{@base_plt}
        --apps #{Enum.join(@otp_apps, " ")}
        -pa #{elixir_ebin()}
        -r #{elixir_ebin()}
        |)
    end

    # Build project plt
    File.mkdir_p!(Path.join(@tmp_dir, "proj_plt"))
    plt_path = Path.join(@tmp_dir, "proj_plt/proj_plt_#{datetime_now()}.plt")
    run_dialyzer(~w|
      --add_to_plt
      --plt #{@base_plt}
      --output_plt #{plt_path}
      -pa #{elixir_ebin()}
      | ++ Enum.flat_map(beams_paths, &~w|-r #{&1}|))

    plt_path
  end

  defp build_call_graph(plt_path, beams_paths) do
    File.mkdir_p!(Path.join(@tmp_dir, "callgraph"))
    callgraph_path = Path.join(@tmp_dir, "callgraph/callgraph_#{datetime_now()}.dot")
    run_dialyzer(~w|
      --dump_callgraph #{callgraph_path}
      --plt #{plt_path}
      -pa #{elixir_ebin()}
    | ++ Enum.flat_map(beams_paths, &~w|-r #{&1}|))

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
    case System.cmd("dialyzer", args, [stderr_to_stdout: true] ++ cmd_args) do
      {_output, code} when code in 0..2 ->
        # 0 = success, 1 = warnings, 2 = unknown functions — all acceptable
        # for PLT build/update; the file is written regardless.
        :ok

      {output, code} ->
        raise "Unexpected dialyzer result: #{code}, output: \n#{output}"
    end
  end

  defp datetime_now() do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
