defmodule TreeshakeTest do
  use ExUnit.Case, async: true

  import AsyncTest

  @fixture Path.expand("fixtures/demo_app", __DIR__)

  @moduletag :tmp_dir

  # Compile the fixture project once before any tests in this module run.
  # We target the prod env so the _build layout matches what treeshake expects.
  setup_all do
    {output, code} =
      System.cmd("mix", ~w(compile --force),
        cd: @fixture,
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    if code != 0, do: flunk("Fixture failed to compile:\n#{output}")

    :ok
  end

  defp treeshake(ctx, opts) do
    Treeshake.run([project: @fixture, tmp_dir: ctx.tmp_dir] ++ opts)
  end

  async_test "module-level removal", %{tmp_dir: tmp_dir} = ctx do
    output_dir = Path.join(tmp_dir, "out")

    stats = treeshake(ctx, output_dir: output_dir)

    refute DemoApp.Application in stats.modules_removed
    refute DemoApp.Worker in stats.modules_removed
    assert DemoApp.DeadModule in stats.modules_removed
    assert DemoApp.AnotherDead in stats.modules_removed
    assert DemoApp in stats.modules_removed

    surviving =
      output_dir
      |> File.ls!()
      |> Enum.flat_map(fn
        "Elixir.DemoApp." <> app_module -> [app_module]
        _other -> []
      end)
      |> Enum.sort()

    assert ~w|Application.beam Behaviour.beam BehaviourImpl.beam BehaviourImplDep.beam Worker.beam| =
             surviving
  end

  describe "function-level removal" do
    async_test "removes unused/1 from DemoApp.Worker (non-dead module)",
               %{tmp_dir: tmp_dir} = ctx do
      output_dir = Path.join(tmp_dir, "out")
      stats = treeshake(ctx, output_dir: output_dir)

      assert {DemoApp.Worker, :unused, 1} in stats.functions_removed
    end

    async_test "unused/1 is not callable after tree-shaking", %{tmp_dir: tmp_dir} = ctx do
      output_dir = Path.join(tmp_dir, "out")

      treeshake(ctx, output_dir: output_dir)

      beam_path = Path.join(output_dir, "Elixir.DemoApp.Worker.beam")
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

  async_test "dry run", %{tmp_dir: tmp_dir} = ctx do
    output_dir = Path.join(tmp_dir, "out")
    ebin = Path.join([@fixture, "_build", "prod", "lib", "demo_app", "ebin"])
    before_files = ebin |> File.ls!() |> Enum.sort()

    stats = treeshake(ctx, output_dir: output_dir, dry_run: true)

    assert DemoApp.DeadModule in stats.modules_removed
    assert DemoApp.AnotherDead in stats.modules_removed

    refute File.exists?(output_dir)

    assert before_files == ebin |> File.ls!() |> Enum.sort()
  end

  describe "output directory isolation" do
    async_test "original ebin is not modified when --output is set", %{tmp_dir: tmp_dir} = ctx do
      output_dir = Path.join(tmp_dir, "out")
      ebin = Path.join([@fixture, "_build", "prod", "lib", "demo_app", "ebin"])
      before_files = ebin |> File.ls!() |> Enum.sort()

      treeshake(ctx, output_dir: output_dir)

      assert before_files == ebin |> File.ls!() |> Enum.sort()
    end
  end

  @tag :behaviour
  async_test "behaviour", %{tmp_dir: tmp_dir} = ctx do
    output_dir = Path.join(tmp_dir, "out")

    stats = treeshake(ctx, output_dir: output_dir)
    refute DemoApp.Behaviour in stats.modules_removed
    refute DemoApp.BehaviourImpl in stats.modules_removed
    refute DemoApp.BehaviourImplDep in stats.modules_removed
  end

  @tag :correctness
  async_test "surviving modules are callable after tree-shaking", %{tmp_dir: tmp_dir} = ctx do
    output_dir = Path.join(tmp_dir, "out")

    stats =
      treeshake(ctx,
        output_dir: output_dir,
        extra_entry_points: [
          {Elixir.Supervisor.Default, :init, 1},
          {IO, :inspect, 1}
        ]
      )

    _stats = stats
    # dbg(stats.modules_removed, limit: :infinity)
    # dbg(stats.functions_removed, limit: :infinity)

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

    {:ok, :treeshake_runner} =
      :compile.file(String.to_charlist(helper_src),
        outdir: String.to_charlist(output_dir)
      )

    {output, exit_code} =
      System.cmd(
        erl,
        ~w|-noshell -noinput -pa #{output_dir} -run treeshake_runner run|,
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "erl subprocess failed (exit #{exit_code}): missing module or wrong result\n#{output}"
  end
end
