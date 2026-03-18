defmodule TreeshakeTest do
  use ExUnit.Case

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
    test "removes entirely unreachable modules", %{tmp_dir: output_dir} do
      assert {:ok, stats} = Treeshake.run(@fixture, output_dir: output_dir, mix_env: "prod")

      assert DemoApp.DeadModule in stats.modules_removed
      assert DemoApp.AnotherDead in stats.modules_removed
      # The top-level DemoApp scaffold module is also never called
      assert DemoApp in stats.modules_removed
    end

    test "keeps reachable modules", %{tmp_dir: output_dir} do
      assert {:ok, stats} = Treeshake.run(@fixture, output_dir: output_dir, mix_env: "prod")

      refute DemoApp.Application in stats.modules_removed
      refute DemoApp.Worker in stats.modules_removed
    end

    test "deletes BEAM files for dead modules", %{tmp_dir: output_dir} do
      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, mix_env: "prod")

      refute File.exists?(Path.join(output_dir, "Elixir.DemoApp.DeadModule.beam"))
      refute File.exists?(Path.join(output_dir, "Elixir.DemoApp.AnotherDead.beam"))
      refute File.exists?(Path.join(output_dir, "Elixir.DemoApp.beam"))
    end

    test "keeps BEAM files for live modules", %{tmp_dir: output_dir} do
      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, mix_env: "prod")

      assert File.exists?(Path.join(output_dir, "Elixir.DemoApp.Application.beam"))
      assert File.exists?(Path.join(output_dir, "Elixir.DemoApp.Worker.beam"))
    end

    test "output contains only the surviving BEAMs", %{tmp_dir: output_dir} do
      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, mix_env: "prod")

      surviving = output_dir |> File.ls!() |> Enum.sort()
      assert surviving == ["Elixir.DemoApp.Application.beam", "Elixir.DemoApp.Worker.beam"]
    end
  end

  describe "dry run" do
    test "does not write or delete any files", %{tmp_dir: output_dir} do
      ebin = Path.join([@fixture, "_build", "prod", "lib", "demo_app", "ebin"])
      before_files = ebin |> File.ls!() |> Enum.sort()

      assert {:ok, _stats} =
               Treeshake.run(@fixture, dry_run: true, mix_env: "prod", output_dir: output_dir)

      # Output directory must be empty
      assert File.ls!(output_dir) == []
      # Original ebin is untouched
      assert ^before_files = ebin |> File.ls!() |> Enum.sort()
    end

    test "still reports what would be removed", %{tmp_dir: output_dir} do
      assert {:ok, stats} =
               Treeshake.run(@fixture, dry_run: true, mix_env: "prod", output_dir: output_dir)

      assert DemoApp.DeadModule in stats.modules_removed
      assert DemoApp.AnotherDead in stats.modules_removed
      assert stats.modules_removed != []
    end
  end

  describe "output directory isolation" do
    test "original ebin is not modified when --output is set", %{tmp_dir: output_dir} do
      ebin = Path.join([@fixture, "_build", "prod", "lib", "demo_app", "ebin"])
      before_files = ebin |> File.ls!() |> Enum.sort()

      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, mix_env: "prod")

      assert ^before_files = ebin |> File.ls!() |> Enum.sort()
    end
  end

  describe "correctness" do
    test "surviving modules are callable after tree-shaking", %{tmp_dir: output_dir} do
      assert {:ok, _stats} = Treeshake.run(@fixture, output_dir: output_dir, mix_env: "prod")

      survivors = [DemoApp.Application, DemoApp.Worker]

      on_exit(fn ->
        Enum.each(survivors, fn mod ->
          :code.purge(mod)
          :code.delete(mod)
        end)
      end)

      Enum.each(survivors, fn mod ->
        beam_path = Path.join(output_dir, "#{Atom.to_string(mod)}.beam")
        {:ok, binary} = File.read(beam_path)
        assert {:module, ^mod} = :code.load_binary(mod, String.to_charlist(beam_path), binary)
      end)

      assert apply(DemoApp.Worker, :process, ["hello"]) == "[HELLO]"
    end
  end
end
