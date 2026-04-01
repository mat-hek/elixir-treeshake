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

  describe "module-level removal" do
    @tag :skip
    async_test "removes entirely unreachable modules", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      assert {:ok, stats} = Treeshake.run(@fixture, output_dir: output_dir, tmp_dir: tmp_dir)

      assert DemoApp.DeadModule in stats.modules_removed
      assert DemoApp.AnotherDead in stats.modules_removed
      # The top-level DemoApp scaffold module is also never called
      assert DemoApp in stats.modules_removed
    end

    @tag :skip
    async_test "keeps reachable modules", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      assert {:ok, stats} = Treeshake.run(@fixture, output_dir: output_dir, tmp_dir: tmp_dir)

      refute DemoApp.Application in stats.modules_removed
      refute DemoApp.Worker in stats.modules_removed
    end

    @tag :skip
    async_test "deletes BEAM files for dead modules", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, tmp_dir: tmp_dir)

      refute File.exists?(Path.join(output_dir, "Elixir.DemoApp.DeadModule.beam"))
      refute File.exists?(Path.join(output_dir, "Elixir.DemoApp.AnotherDead.beam"))
      refute File.exists?(Path.join(output_dir, "Elixir.DemoApp.beam"))
    end

    @tag :skip
    async_test "keeps BEAM files for live modules", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, tmp_dir: tmp_dir)

      assert File.exists?(Path.join(output_dir, "Elixir.DemoApp.Application.beam"))
      assert File.exists?(Path.join(output_dir, "Elixir.DemoApp.Worker.beam"))
    end

    @tag :skip
    async_test "output contains only the surviving BEAMs", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, tmp_dir: tmp_dir)

      surviving = output_dir |> File.ls!() |> Enum.sort()
      assert surviving == ["Elixir.DemoApp.Application.beam", "Elixir.DemoApp.Worker.beam"]
    end
  end

  describe "function-level removal" do
    @tag :skip
    async_test "removes unused/1 from DemoApp.Worker (non-dead module)", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      assert {:ok, stats} = Treeshake.run(@fixture, output_dir: output_dir, tmp_dir: tmp_dir)

      assert {DemoApp.Worker, :unused, 1} in stats.functions_removed
    end

    @tag :skip
    async_test "unused/1 is not callable after tree-shaking", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, tmp_dir: tmp_dir)

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

  describe "dry run" do
    @tag :skip
    async_test "does not write or delete any files", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      ebin = Path.join([@fixture, "_build", "prod", "lib", "demo_app", "ebin"])
      before_files = ebin |> File.ls!() |> Enum.sort()

      assert {:ok, _stats} =
               Treeshake.run(@fixture, dry_run: true, tmp_dir: tmp_dir, output_dir: output_dir)

      # Output directory must be empty
      refute File.exists?(output_dir)
      # Original ebin is untouched
      assert ^before_files = ebin |> File.ls!() |> Enum.sort()
    end

    @tag :skip
    async_test "still reports what would be removed", %{tmp_dir: tmp_dir} do
      assert {:ok, stats} = Treeshake.run(@fixture, dry_run: true, tmp_dir: tmp_dir)

      assert DemoApp.DeadModule in stats.modules_removed
      assert DemoApp.AnotherDead in stats.modules_removed
      assert stats.modules_removed != []
    end
  end

  describe "output directory isolation" do
    @tag :skip
    async_test "original ebin is not modified when --output is set", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      ebin = Path.join([@fixture, "_build", "prod", "lib", "demo_app", "ebin"])
      before_files = ebin |> File.ls!() |> Enum.sort()

      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, tmp_dir: tmp_dir)

      assert ^before_files = ebin |> File.ls!() |> Enum.sort()
    end
  end

  describe "protocol implementations" do
    # These tests call BeamRewriter directly with a crafted reachable set so we
    # can control exactly which modules Dialyzer "saw" — isolating the protocol
    # enrichment logic without running a full Dialyzer analysis.

    @tag :skip
    test "keeps impl when protocol is reachable but impl was not in call graph", _context do
      ebin = Path.join([@fixture, "_build", "prod", "lib", "demo_app", "ebin"])
      all_beams = Path.wildcard(Path.join(ebin, "*.beam"))

      # Simulate: Dialyzer saw DemoApp.Formatter (protocol) but missed the
      # dynamic-dispatch edge to DemoApp.Formatter.Integer (implementation).
      reachable = %{
        mfas: MapSet.new([{DemoApp.Formatter, :format, 1}]),
        modules: MapSet.new([DemoApp.Formatter])
      }

      stats = Treeshake.BeamRewriter.rewrite(all_beams, reachable, dry_run: true)

      refute DemoApp.Formatter.Integer in stats.modules_removed
    end

    @tag :skip
    test "removes impl when its protocol is not reachable", _context do
      ebin = Path.join([@fixture, "_build", "prod", "lib", "demo_app", "ebin"])
      all_beams = Path.wildcard(Path.join(ebin, "*.beam"))

      # Protocol itself is not reachable — implementation should be removed too.
      reachable = %{
        mfas: MapSet.new(),
        modules: MapSet.new()
      }

      stats = Treeshake.BeamRewriter.rewrite(all_beams, reachable, dry_run: true)

      assert DemoApp.Formatter.Integer in stats.modules_removed
    end
  end

  describe "correctness" do
    @tag :target
    @tag timeout: :infinity
    async_test "surviving modules are callable after tree-shaking", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")

      assert {:ok, stats} =
               Treeshake.run(@fixture,
                 output_dir: output_dir,
                 #  tmp_dir: tmp_dir,
                 tmp_subdir: "correctness_test",
                 extra_entry_points: [
                   {HelloPopcorn, :child_spec, 1},
                   {HelloPopcorn, :start_link, 1},
                   {Elixir.Supervisor.Default, :init, 1}
                 ]
               )

      dbg(stats.modules_removed, limit: :infinity)
      dbg(stats.functions_removed, limit: :infinity)

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
          ["-noshell", "-noinput", "-pa", output_dir, "-run", "treeshake_runner", "run"],
          stderr_to_stdout: true
        )

      assert exit_code == 0,
             "erl subprocess failed (exit #{exit_code}): missing module or wrong result\n#{output}"
    end
  end
end
