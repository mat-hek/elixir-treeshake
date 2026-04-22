defmodule Treeshake.Utils.BeamRenamerTest do
  use ExUnit.Case, async: true

  alias Treeshake.Utils.BeamRenamer

  @ebin "test/fixtures/demo_app/_build/prod/lib/demo_app/ebin"

  defp beam(module), do: Path.join(@ebin, "#{module}.beam") |> String.to_charlist()

  defp make_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "beam_renamer_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp module_from_beam(path) do
    {:ok, mod, _chunks} = :beam_lib.all_chunks(String.to_charlist(path))
    mod
  end

  describe "rename/3 - output file" do
    test "writes a file named after the new module" do
      out = make_tmp_dir()
      on_exit(fn -> File.rm_rf!(out) end)

      BeamRenamer.rename(beam("Elixir.DemoApp.Worker"), :"Elixir.DemoApp.Renamed", out)

      assert File.exists?(Path.join(out, "Elixir.DemoApp.Renamed.beam"))
    end

    test "does not write a file with the old module name" do
      out = make_tmp_dir()
      on_exit(fn -> File.rm_rf!(out) end)

      BeamRenamer.rename(beam("Elixir.DemoApp.Worker"), :"Elixir.DemoApp.Renamed", out)

      refute File.exists?(Path.join(out, "Elixir.DemoApp.Worker.beam"))
    end
  end

  describe "rename/3 - module name in output BEAM" do
    test "resulting BEAM reports the new module name" do
      out = make_tmp_dir()
      on_exit(fn -> File.rm_rf!(out) end)

      BeamRenamer.rename(beam("Elixir.DemoApp.Worker"), :"Elixir.DemoApp.Renamed", out)

      new_beam = Path.join(out, "Elixir.DemoApp.Renamed.beam")
      assert module_from_beam(new_beam) == :"Elixir.DemoApp.Renamed"
    end

    test "resulting BEAM does not report the old module name" do
      out = make_tmp_dir()
      on_exit(fn -> File.rm_rf!(out) end)

      BeamRenamer.rename(beam("Elixir.DemoApp.Worker"), :"Elixir.DemoApp.Renamed", out)

      new_beam = Path.join(out, "Elixir.DemoApp.Renamed.beam")
      refute module_from_beam(new_beam) == :"Elixir.DemoApp.Worker"
    end
  end

  describe "rename/3 - BEAM validity" do
    test "output is a valid BEAM (all_chunks succeeds)" do
      out = make_tmp_dir()
      on_exit(fn -> File.rm_rf!(out) end)

      BeamRenamer.rename(beam("Elixir.DemoApp.Worker"), :"Elixir.DemoApp.ValidCheck", out)

      new_beam = Path.join(out, "Elixir.DemoApp.ValidCheck.beam")
      assert {:ok, :"Elixir.DemoApp.ValidCheck", _chunks} =
               :beam_lib.all_chunks(String.to_charlist(new_beam))
    end

    test "output is loadable by the runtime" do
      out = make_tmp_dir()
      on_exit(fn ->
        :code.purge(:"Elixir.DemoApp.Loadable")
        :code.delete(:"Elixir.DemoApp.Loadable")
        File.rm_rf!(out)
      end)

      BeamRenamer.rename(beam("Elixir.DemoApp.Worker"), :"Elixir.DemoApp.Loadable", out)

      new_beam = Path.join(out, "Elixir.DemoApp.Loadable.beam")
      {:ok, binary} = File.read(new_beam)

      assert {:module, :"Elixir.DemoApp.Loadable"} =
               :code.load_binary(
                 :"Elixir.DemoApp.Loadable",
                 String.to_charlist(new_beam),
                 binary
               )
    end

    test "module_info/0 reports the new module name after loading" do
      mod = :"Elixir.DemoApp.ModuleInfoCheck"
      out = make_tmp_dir()

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
        File.rm_rf!(out)
      end)

      BeamRenamer.rename(beam("Elixir.DemoApp.Worker"), mod, out)

      new_beam = Path.join(out, "#{mod}.beam")
      {:ok, binary} = File.read(new_beam)
      :code.load_binary(mod, String.to_charlist(new_beam), binary)

      assert mod.module_info(:module) == mod
    end

    test "chunks are preserved from original" do
      out = make_tmp_dir()
      on_exit(fn -> File.rm_rf!(out) end)

      {:ok, _old_mod, old_chunks} =
        :beam_lib.all_chunks(beam("Elixir.DemoApp.Worker"))

      BeamRenamer.rename(beam("Elixir.DemoApp.Worker"), :"Elixir.DemoApp.ChunkCheck", out)

      new_beam = Path.join(out, "Elixir.DemoApp.ChunkCheck.beam")
      {:ok, _, new_chunks} = :beam_lib.all_chunks(String.to_charlist(new_beam))

      old_names = Enum.map(old_chunks, &elem(&1, 0)) |> Enum.sort()
      new_names = Enum.map(new_chunks, &elem(&1, 0)) |> Enum.sort()

      assert old_names == new_names
    end
  end

  describe "rename/3 - empty module from Code.compile_quoted" do
    test "renames the module and module_info/1 returns the new name" do
      src_mod = :"Elixir.BeamRenamerTest.EmptySource"
      new_mod = :"Elixir.BeamRenamerTest.EmptyRenamed"

      [{^src_mod, beam_binary}] =
        quote do
          defmodule unquote(src_mod) do
          end
        end
        |> Code.compile_quoted()

      out = make_tmp_dir()

      on_exit(fn ->
        :code.purge(src_mod)
        :code.delete(src_mod)
        :code.purge(new_mod)
        :code.delete(new_mod)
        File.rm_rf!(out)
      end)

      BeamRenamer.rename(beam_binary, new_mod, out)

      new_beam = Path.join(out, "#{new_mod}.beam")
      assert File.exists?(new_beam)
      assert module_from_beam(new_beam) == new_mod

      {:ok, binary} = File.read(new_beam)
      :code.load_binary(new_mod, String.to_charlist(new_beam), binary)
      assert new_mod.module_info(:module) == new_mod
    end
  end

  describe "rename/3 - different source modules" do
    test "renames DemoApp.Application" do
      out = make_tmp_dir()
      on_exit(fn -> File.rm_rf!(out) end)

      BeamRenamer.rename(
        beam("Elixir.DemoApp.Application"),
        :"Elixir.DemoApp.RenamedApp",
        out
      )

      assert module_from_beam(Path.join(out, "Elixir.DemoApp.RenamedApp.beam")) ==
               :"Elixir.DemoApp.RenamedApp"
    end
  end

  describe "rename/3 - error cases" do
    test "raises when input file does not exist" do
      out = make_tmp_dir()
      on_exit(fn -> File.rm_rf!(out) end)

      assert_raise MatchError, fn ->
        BeamRenamer.rename(~c"/tmp/no_such_file_for_renamer.beam", :"Elixir.Foo", out)
      end
    end
  end
end
