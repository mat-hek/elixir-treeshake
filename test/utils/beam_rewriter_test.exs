defmodule Treeshake.Utils.BeamRewriterTest do
  use ExUnit.Case, async: true

  alias Treeshake.Utils.BeamRewriter

  @fixture Path.expand("../fixtures/demo_app", __DIR__)
  @ebin Path.expand("../fixtures/demo_app/_build/prod/lib/demo_app/ebin", __DIR__)

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

  defp beam(module), do: Path.join(@ebin, "#{module}.beam")

  defp abstract_functions(binary) when is_binary(binary) do
    {:ok, {_mod, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(binary, [:abstract_code])

    for {:function, _, name, arity, _} <- forms, do: {name, arity}
  end

  defp beam_exports(binary) when is_binary(binary) do
    {:ok, {_mod, [exports: exports]}} = :beam_lib.chunks(binary, [:exports])
    exports
  end

  # ---------------------------------------------------------------------------
  # Happy-path
  # ---------------------------------------------------------------------------

  # process/1 calls upcase/1 and wrap/1 — the caller is responsible for
  # passing the full set including local dependencies.
  @worker_process_funs [process: 1, upcase: 1, wrap: 1]

  describe "keep_funs/2 - basic" do
    test "returns {binary, removed}" do
      assert {binary, removed} =
               BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), @worker_process_funs)

      assert is_binary(binary)
      assert is_list(removed)
    end

    test "kept function is present in abstract code" do
      {binary, _} = BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), @worker_process_funs)
      assert {:process, 1} in abstract_functions(binary)
    end

    test "non-kept function is absent from abstract code" do
      {binary, _} = BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), @worker_process_funs)
      refute {:unused, 1} in abstract_functions(binary)
    end

    test "kept function is present in exports" do
      {binary, _} = BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), @worker_process_funs)
      assert {:process, 1} in beam_exports(binary)
    end

    test "non-kept function is absent from exports" do
      {binary, _} = BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), @worker_process_funs)
      refute {:unused, 1} in beam_exports(binary)
    end

    test "removed list contains the stripped function" do
      {_, removed} = BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), @worker_process_funs)
      assert {:unused, 1} in removed
    end

    test "removed list does not contain kept functions" do
      {_, removed} = BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), @worker_process_funs)
      refute {:process, 1} in removed
    end
  end

  describe "keep_funs/2 - multiple functions" do
    test "all listed functions are present" do
      {binary, _} =
        BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), [
          process: 1,
          unused: 1,
          upcase: 1,
          wrap: 1
        ])

      funs = abstract_functions(binary)
      assert {:process, 1} in funs
      assert {:unused, 1} in funs
    end

    test "none of the explicitly kept functions appear in removed" do
      keep = [process: 1, unused: 1, upcase: 1, wrap: 1]
      {_, removed} = BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), keep)
      for fa <- keep, do: refute(fa in removed)
    end
  end

  describe "keep_funs/2 - empty list" do
    test "returns binary with no user-defined functions and all as removed" do
      {binary, removed} = BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), [])
      assert is_binary(binary)
      assert abstract_functions(binary) == []
      assert {:unused, 1} in removed
      assert {:process, 1} in removed
    end
  end

  describe "keep_funs/2 - function not present" do
    test "silently ignores names not in the module" do
      {binary, _removed} =
        BeamRewriter.keep_funs(beam("Elixir.DemoApp.Worker"), [totally_absent: 99])

      assert is_binary(binary)
    end
  end

  # ---------------------------------------------------------------------------
  # Error cases
  # ---------------------------------------------------------------------------

  describe "keep_funs/2 - errors" do
    test "raises for a non-existent file" do
      assert_raise RuntimeError, ~r/failed to read BEAM|unexpected error/, fn ->
        BeamRewriter.keep_funs("/tmp/no_such_file_at_all.beam", [foo: 1])
      end
    end

    test "raises for a file with no debug_info" do
      forms = [
        {:attribute, 1, :module, :NoDebugInfoMod},
        {:attribute, 2, :export, [{:hello, 0}]},
        {:function, 3, :hello, 0, [{:clause, 3, [], [], [{:atom, 3, :ok}]}]}
      ]

      {:ok, :NoDebugInfoMod, binary, _} = :compile.forms(forms, [:return_errors, :return_warnings])
      tmp = Path.join(System.tmp_dir!(), "no_debug_info_#{:erlang.unique_integer([:positive])}.beam")
      File.write!(tmp, binary)
      on_exit(fn -> File.rm(tmp) end)

      assert_raise RuntimeError, ~r/no abstract code/, fn ->
        BeamRewriter.keep_funs(tmp, [hello: 0])
      end
    end
  end
end
