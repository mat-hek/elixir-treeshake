defmodule Treeshake.Utils.BeamReaderTest do
  use ExUnit.Case, async: true

  alias Treeshake.Utils.BeamReader

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

    File.mkdir_p!("test/fixtures/ebin")
    File.cp!(List.to_string(:code.which(Task)), "test/fixtures/ebin/Elixir.Task.beam")

    :ok
  end

  defp beam(module), do: Path.join(@ebin, "#{module}.beam")

  defp find_fun(functions, name, arity) do
    Enum.find(functions, &(&1.name == name and &1.arity == arity))
  end

  describe "read/2 - errors" do
    test "returns :error for a non-existent file" do
      assert :error = BeamReader.read("/tmp/does_not_exist_at_all.beam")
    end
  end

  describe "read/2 - module metadata" do
    test "returns the module atom" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Worker))
      assert info.module == DemoApp.Worker
    end

    test "no :callbacks key for a non-behaviour module" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Worker))
      refute Map.has_key?(info, :callbacks)
    end

    test "no :callbacks key for a behaviour implementor (not itself a behaviour)" do
      {:ok, info} = BeamReader.read(beam(DemoApp.BehaviourImpl))
      refute Map.has_key?(info, :callbacks)
    end
  end

  describe "read/2 - public / private" do
    test "exported functions are marked public" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Worker))

      assert find_fun(info.functions, :process, 1).public == true
      assert find_fun(info.functions, :unused, 1).public == true
    end

    test "non-exported functions are marked private" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Worker))

      assert find_fun(info.functions, :upcase, 1).public == false
      assert find_fun(info.functions, :wrap, 1).public == false
    end

    test "all four functions of DemoApp.Worker are present" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Worker))
      names = Enum.map(info.functions, &{&1.name, &1.arity})

      assert {:process, 1} in names
      assert {:unused, 1} in names
      assert {:upcase, 1} in names
      assert {:wrap, 1} in names
    end
  end

  describe "read/2 - calls" do
    test "process/1 calls private helpers locally" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Worker))
      calls = find_fun(info.functions, :process, 1).calls

      assert {nil, :upcase, 1} in calls
      assert {nil, :wrap, 1} in calls
    end

    test "upcase/1 calls String.upcase/1 remotely" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Worker))
      calls = find_fun(info.functions, :upcase, 1).calls

      assert {String, :upcase, 1} in calls
    end

    test "BehaviourImpl.hello/0 calls BehaviourImplDep.print_hello/0 remotely" do
      {:ok, info} = BeamReader.read(beam(DemoApp.BehaviourImpl))
      calls = find_fun(info.functions, :hello, 0).calls

      assert {DemoApp.BehaviourImplDep, :print_hello, 0} in calls
    end

    test "standalone atom literals go into potential_modules, not calls" do
      {:ok, info} = BeamReader.read(beam(DemoApp.BehaviourImpl))
      hello = find_fun(info.functions, :hello, 0)

      # :ok is a standalone atom literal — not part of a call or MFA tuple
      assert :ok in hello.potential_modules
      refute :ok in hello.calls

      # The remote-call module is represented in calls, not in potential_modules
      assert {DemoApp.BehaviourImplDep, :print_hello, 0} in hello.calls
      refute DemoApp.BehaviourImplDep in hello.potential_modules
    end

    test "calls list has no duplicates" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Worker))

      for func <- info.functions do
        assert func.calls == Enum.uniq(func.calls),
               "duplicate calls in #{func.name}/#{func.arity}"
      end
    end
  end

  describe "read/2 - callbacks" do
    test "behaviour module exposes its callbacks" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Behaviour))

      assert Map.has_key?(info, :callbacks)
      assert {:hello, 0} in info.callbacks
    end
  end

  describe "read/2 - matching_terms" do
    test "default filter yields no matching terms" do
      {:ok, info} = BeamReader.read(beam(DemoApp.Worker))

      assert Enum.all?(info.functions, &(&1.matching_terms == []))
    end

    test "filter returning {:match, value} collects value — atom literal" do
      # Filter receives the reconstructed shape: the atom :ok, not {:atom, _, :ok}
      filter = fn
        :ok -> {:match, :ok}
        _ -> :ignore
      end

      {:ok, info} = BeamReader.read(beam(DemoApp.BehaviourImpl), filter)
      hello = find_fun(info.functions, :hello, 0)

      assert :ok in hello.matching_terms
    end

    test "filter can extract a transformed value" do
      # Collect all atom values (filter receives plain atoms, not AST nodes)
      filter = fn
        v when is_atom(v) -> {:match, v}
        _ -> :ignore
      end

      {:ok, info} = BeamReader.read(beam(DemoApp.BehaviourImpl), filter)
      hello = find_fun(info.functions, :hello, 0)

      assert DemoApp.BehaviourImplDep in hello.matching_terms
      assert :ok in hello.matching_terms
    end

    test "filter returning {:match, value} collects value — integer literal" do
      # unused/1 body: foo + 1; filter receives the plain integer 1
      filter = fn
        n when is_integer(n) -> {:match, n}
        _ -> :ignore
      end

      {:ok, info} = BeamReader.read(beam(DemoApp.Worker), filter)
      unused = find_fun(info.functions, :unused, 1)

      assert 1 in unused.matching_terms
    end

    test "non-{:match, _} return values are ignored" do
      filter = fn _ -> false end

      {:ok, info} = BeamReader.read(beam(DemoApp.BehaviourImpl), filter)
      hello = find_fun(info.functions, :hello, 0)

      assert hello.matching_terms == []
    end

    test "matching_terms has no duplicates" do
      filter = fn
        v when is_atom(v) -> {:match, v}
        _ -> :ignore
      end

      {:ok, info} = BeamReader.read(beam(DemoApp.Worker), filter)

      for func <- info.functions do
        assert func.matching_terms == Enum.uniq(func.matching_terms),
               "duplicate matching_terms in #{func.name}/#{func.arity}"
      end
    end
  end

  @tag :task
  test "hardcoded MFA tuple {Mod, :fun, arity} appears in calls" do
    {:ok, info} = BeamReader.read("test/fixtures/ebin/Elixir.Task.beam")
    child_spec = Enum.find(info.functions, &(&1.name == :child_spec))

    # Task.child_spec/1 contains the literal {Task, :start_link, [arg]} — arity 1
    assert {Task, :start_link, 1} in child_spec.calls

    # Task atom from `id: Task` goes into potential_modules, not calls
    assert Task in child_spec.potential_modules
    refute Task in child_spec.calls
  end

  test "task" do
    assert {:ok, info} =
             Treeshake.Utils.BeamReader.read("test/fixtures/ebin/Elixir.Task.beam", fn
               {m, f, a} when is_atom(m) and is_atom(f) and (is_integer(a) or is_list(a)) ->
                 {:match, {m, f, a}}

               _ ->
                 false
             end)

    assert child_spec = Enum.find(info.functions, &(&1.name == :child_spec))

    assert Enum.find(child_spec, fn
             {Task, :start_link, _args} -> true
             _other -> false
           end)
  end
end
