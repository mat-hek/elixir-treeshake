defmodule TreeshakeTest do
  use ExUnit.Case, async: true

  import AsyncTest

  @fixture Path.expand("fixtures/demo_app", __DIR__)

  @moduletag :tmp_dir

  defp treeshake(opts) do
    Treeshake.run([project: @fixture] ++ opts)
  end

  setup_all do
    tmp_dir = "tmp/treeshake_test"
    out_dir = Path.join(tmp_dir, "out")
    File.mkdir_p!(tmp_dir)
    stats = treeshake(tmp_dir: tmp_dir, output_dir: out_dir)
    %{treeshake: %{stats: stats, out_dir: out_dir}}
  end

  async_test "module-level removal", %{treeshake: %{stats: stats, out_dir: out_dir}} do
    refute DemoApp.Application in stats.modules_removed
    refute DemoApp.Worker in stats.modules_removed
    assert DemoApp.DeadModule in stats.modules_removed
    assert DemoApp.AnotherDead in stats.modules_removed
    assert DemoApp in stats.modules_removed

    surviving =
      out_dir
      |> File.ls!()
      |> Enum.flat_map(fn
        "Elixir.DemoApp." <> app_module -> [app_module]
        _other -> []
      end)
      |> Enum.sort()

    assert ~w|Application.beam Behaviour.beam BehaviourImpl.beam BehaviourImplDep.beam Formatter.DemoApp.Widget.beam Formatter.Integer.beam Formatter.beam ProtocolUser.beam Worker.beam| =
             surviving
  end

  describe "function-level removal" do
    async_test "removes unused/1 from DemoApp.Worker (non-dead module)",
               %{treeshake: %{stats: stats}} do
      assert {DemoApp.Worker, :unused, 1} in stats.functions_removed
    end

    async_test "unused/1 is not callable after tree-shaking", %{
      treeshake: %{out_dir: out_dir}
    } do
      beam_path = Path.join(out_dir, "Elixir.DemoApp.Worker.beam")
      {:ok, binary} = File.read(beam_path)

      assert {:module, DemoApp.Worker} =
               :code.load_binary(DemoApp.Worker, String.to_charlist(beam_path), binary)

      on_exit(fn ->
        :code.purge(DemoApp.Worker)
        :code.delete(DemoApp.Worker)
      end)

      refute function_exported?(DemoApp.Worker, :unused, 1)
    end
  end

  async_test "dry run", %{tmp_dir: tmp_dir} do
    ebin = Path.join([@fixture, "_build", "prod", "lib", "demo_app", "ebin"])
    before_files = ebin |> File.ls!() |> Enum.sort()
    out_dir = Path.join(tmp_dir, "out")

    stats = treeshake(tmp_dir: tmp_dir, output_dir: out_dir, dry_run: true)

    assert DemoApp.DeadModule in stats.modules_removed
    assert DemoApp.AnotherDead in stats.modules_removed

    refute File.exists?(out_dir)

    assert before_files == ebin |> File.ls!() |> Enum.sort()
  end

  @tag :behaviour
  async_test "behaviour", %{treeshake: %{stats: stats}} do
    refute DemoApp.Behaviour in stats.modules_removed
    refute DemoApp.BehaviourImpl in stats.modules_removed
    refute DemoApp.BehaviourImplDep in stats.modules_removed
  end

  @tag :correctness
  @tag {:timeout, :infinity}
  async_test "surviving modules are callable after tree-shaking", %{tmp_dir: tmp_dir} do
    output_dir = Path.join(tmp_dir, "out")

    mods = [
      :argparse,
      :array,
      :base64,
      :beam_lib,
      :binary,
      :c,
      :calendar,
      :dets,
      :dets_server,
      :dets_sup,
      :dets_utils,
      :dets_v9,
      :dict,
      :digraph,
      :digraph_utils,
      :edlin,
      :edlin_context,
      :edlin_expand,
      :edlin_type_suggestion,
      :epp,
      :erl_abstract_code,
      :erl_anno,
      :erl_bits,
      :erl_compile,
      :erl_error,
      :erl_eval,
      :erl_expand_records,
      :erl_features,
      :erl_internal,
      :erl_lint,
      :erl_parse,
      :erl_posix_msg,
      :erl_pp,
      :erl_scan,
      :erl_stdlib_errors,
      :erl_tar,
      :error_logger_file_h,
      :error_logger_tty_h,
      :escript,
      :ets,
      :eval_bits,
      :file_sorter,
      :filelib,
      :filename,
      :gb_sets,
      :gb_trees,
      :gen,
      :gen_event,
      :gen_fsm,
      :gen_server,
      :gen_statem,
      :io,
      :io_lib,
      :io_lib_format,
      :io_lib_fread,
      :io_lib_pretty,
      :lists,
      :log_mf_h,
      :maps,
      :math,
      :ms_transform,
      :orddict,
      :ordsets,
      :otp_internal,
      :peer,
      :pool,
      :proc_lib,
      :proplists,
      :qlc,
      :qlc_pt,
      :queue,
      :rand,
      :random,
      :re,
      :sets,
      :shell,
      :shell_default,
      :shell_docs,
      :slave,
      :sofs,
      :string,
      :supervisor,
      :supervisor_bridge,
      :sys,
      :timer,
      :unicode,
      :unicode_util,
      :uri_string,
      :win32reg,
      :zip
    ]

    dbg(mods, limit: :infinity)

    stats =
      treeshake(
        tmp_dir: tmp_dir,
        output_dir: output_dir,
        extra_entry_points: [
          # {:gen_server, :init_it, 6},
          # {:gen_server, :wake_hib, 6},
          # {:gen_statem, :init_it, 6},
          # {:gen_statem, :wakeup_from_hibernate, 3},
          # {:proc_lib, :wake_up, 3},
          # {:c, :erlangrc, 0}
        ]
      )

    _stats = stats
    # dbg(stats.modules_removed, limit: :infinity)

    # dbg_rem = stats.functions_removed |> Enum.filter(fn {m, _f, _a} -> m == :gen end)
    # dbg(dbg_rem, limit: :infinity)

    [{Treeshake.EmptyStub, empty_stub}] =
      quote do
        defmodule Treeshake.EmptyStub do
        end
      end
      |> Code.compile_quoted()

    stubs_dir = Path.join(tmp_dir, "out_stubs")
    File.mkdir_p!(stubs_dir)

    for m <- stats.modules_removed do
      Treeshake.Utils.BeamRenamer.rename(empty_stub, m, stubs_dir)
    end

    erl = Path.join([:code.root_dir() |> to_string(), "bin", "erl"])

    # Write and compile a small Erlang helper so we can use -run instead of
    # -eval.  -eval requires erl_eval, which tree-shaking removes; -run uses
    # apply/3 inside the ERTS init module and needs no erl_eval.
    helper_src = Path.join(tmp_dir, "treeshake_runner.erl")

    File.write!(helper_src, """
    -module(treeshake_runner).
    -export([run/0]).
    run() ->
        Result = 'Elixir.DemoApp.Application':start(nil, nil),
        case Result of
            {ok, _Pid}  -> erlang:halt(0);
            Error ->
              erlang:display(Error),
              erlang:halt(1)
        end.
    """)

    runner_dir = Path.join(tmp_dir, "treeshake_runner")
    File.mkdir!(runner_dir)

    {:ok, :treeshake_runner} =
      :compile.file(String.to_charlist(helper_src),
        outdir: String.to_charlist(runner_dir)
      )

    {output, exit_code} =
      System.cmd(
        erl,
        ~w|-noshell -noinput -pa #{output_dir} -pa #{runner_dir} -pa #{stubs_dir} -run treeshake_runner run|,
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "erl subprocess failed (exit #{exit_code}): missing module or wrong result\n#{output}"

    # mods =
    #   Enum.reduce(mods, mods, fn m, mods ->
    #     File.rm_rf!(output_dir)
    #     File.mkdir!(output_dir)
    #     IO.inspect(m)
    #     IO.inspect(length(mods))

    #     treeshake(ctx,
    #       output_dir: output_dir,
    #       extra_entry_points: [
    #         {Elixir.Supervisor.Default, :init, 1},
    #         {:gen_server, :init_it, 6},
    #         {:gen_server, :wake_hib, 6},
    #         {:gen_statem, :init_it, 6},
    #         {:gen_statem, :wakeup_from_hibernate, 3},
    #         {:proc_lib, :wake_up, 3},
    #         {:application_controller, :start, 1},
    #         {:c, :erlangrc, 0}
    #       ],
    #       non_treeshakable_modules: List.delete(mods, m)
    #     )

    #     for m <- stats.modules_removed do
    #       Treeshake.Utils.BeamRenamer.rename(empty_stub, m, stubs_dir)
    #     end

    #     {output, exit_code} =
    #       System.cmd(
    #         erl,
    #         ~w|-noshell -noinput -pa #{output_dir} -pa #{runner_dir} -pa #{stubs_dir} -run treeshake_runner run|,
    #         stderr_to_stdout: true
    #       )

    #     if exit_code == 0 do
    #       IO.puts("removing")
    #       List.delete(mods, m)
    #     else
    #       IO.puts(
    #         "erl subprocess failed (exit #{exit_code}): missing module or wrong result\n#{output}"
    #       )

    #       mods
    #     end
    #   end)

    # dbg(mods, limit: :infinity)
  end
end
