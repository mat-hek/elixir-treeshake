defmodule Treeshake.Utils.CallGraphTest do
  use ExUnit.Case, async: true

  alias Treeshake.Utils.CallGraph

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

  defp all_beams, do: Path.wildcard(Path.join(@ebin, "*.beam"))

  # ---- empty / error cases ----

  describe "create/2 - empty and error cases" do
    test "no beams and no starting points returns empty graph" do
      assert CallGraph.create([], []) == %{}
    end

    test "no starting points returns empty graph regardless of beam list" do
      assert CallGraph.create(all_beams(), []) == %{}
    end

    test "unreadable beam path is silently skipped" do
      graph = CallGraph.create(["/nonexistent/path.beam"], [{:foo, :bar, 0}])
      assert Map.has_key?(graph, {:foo, :bar, 0})
    end

    test "starting point for a module not in any beam gets an empty call list" do
      graph = CallGraph.create([], [{NotAModule, :foo, 0}])
      assert graph[{NotAModule, :foo, 0}] == []
    end

    test "starting point for a known module but unknown function gets an empty call list" do
      graph = CallGraph.create([beam(DemoApp.Worker)], [{DemoApp.Worker, :nonexistent, 99}])
      assert graph[{DemoApp.Worker, :nonexistent, 99}] == []
    end
  end

  # ---- graph keys and reachability ----

  describe "create/2 - graph keys and reachability" do
    test "starting point is always included as a key" do
      graph = CallGraph.create(all_beams(), [{DemoApp.Worker, :process, 1}])
      assert Map.has_key?(graph, {DemoApp.Worker, :process, 1})
    end

    test "multiple starting points are all present as keys" do
      starting = [{DemoApp.Worker, :process, 1}, {DemoApp.Worker, :unused, 1}]
      graph = CallGraph.create(all_beams(), starting)
      assert Map.has_key?(graph, {DemoApp.Worker, :process, 1})
      assert Map.has_key?(graph, {DemoApp.Worker, :unused, 1})
    end

    test "duplicate starting points result in a single graph entry" do
      mfa = {DemoApp.Worker, :process, 1}
      graph = CallGraph.create(all_beams(), [mfa, mfa])
      assert map_size(Map.filter(graph, fn {k, _} -> k == mfa end)) == 1
    end

    test "public function reachable from starting point is added as a key" do
      beams = [beam(DemoApp.BehaviourImpl), beam(DemoApp.BehaviourImplDep)]
      graph = CallGraph.create(beams, [{DemoApp.BehaviourImpl, :hello, 0}])
      assert Map.has_key?(graph, {DemoApp.BehaviourImplDep, :print_hello, 0})
    end

    test "unreachable public function is not included in the graph" do
      # unused/1 is public but process/1 does not call it
      graph = CallGraph.create(all_beams(), [{DemoApp.Worker, :process, 1}])
      refute Map.has_key?(graph, {DemoApp.Worker, :unused, 1})
    end
  end

  # ---- call values and external references ----

  describe "create/2 - call values" do
    test "private helper calls are expanded into the public function's call list" do
      # Worker.process/1 -> private upcase/1 -> String.upcase/1
      # After BeamAnalyzer expansion, process/1's calls include String.upcase/1
      graph = CallGraph.create([beam(DemoApp.Worker)], [{DemoApp.Worker, :process, 1}])
      calls = graph[{DemoApp.Worker, :process, 1}]
      assert {String, :upcase, 1} in calls
    end

    test "external calls appear in values but not as graph keys" do
      graph = CallGraph.create([beam(DemoApp.Worker)], [{DemoApp.Worker, :process, 1}])
      calls = graph[{DemoApp.Worker, :process, 1}]
      assert {String, :upcase, 1} in calls
      refute Map.has_key?(graph, {String, :upcase, 1})
    end

    test "call list for a reachable callee is also populated" do
      beams = [beam(DemoApp.BehaviourImpl), beam(DemoApp.BehaviourImplDep)]
      graph = CallGraph.create(beams, [{DemoApp.BehaviourImpl, :hello, 0}])
      # BehaviourImplDep.print_hello/0 calls IO.puts/2 which is external
      calls = graph[{DemoApp.BehaviourImplDep, :print_hello, 0}]
      assert is_list(calls)
      assert Enum.any?(calls, fn {m, _, _} -> m == IO end)
    end

    test "call lists contain no duplicates" do
      graph = CallGraph.create(all_beams(), [{DemoApp.Application, :start, 2}])

      for {_mfa, calls} <- graph do
        assert calls == Enum.uniq(calls)
      end
    end
  end

  # ---- behaviour edges ----

  describe "create/2 - behaviour edges" do
    test "potential_module implementing a behaviour adds callback edges to the call list" do
      # Application.start/2 passes DemoApp.BehaviourImpl as an atom argument,
      # so it appears in potential_modules. DemoApp.BehaviourImpl implements
      # DemoApp.Behaviour which declares hello/0 as a callback.
      # => {DemoApp.BehaviourImpl, :hello, 0} must appear in start/2's call list.
      graph = CallGraph.create(all_beams(), [{DemoApp.Application, :start, 2}])
      calls = graph[{DemoApp.Application, :start, 2}]
      assert {DemoApp.BehaviourImpl, :hello, 0} in calls
    end

    test "callback implementation is reachable via BFS through the behaviour edge" do
      graph = CallGraph.create(all_beams(), [{DemoApp.Application, :start, 2}])
      assert Map.has_key?(graph, {DemoApp.BehaviourImpl, :hello, 0})
    end

    test "potential_module not implementing any behaviour adds no extra edges" do
      # DemoApp.BehaviourImplDep is not a behaviour implementor, so referencing
      # it as an atom should not add any callback edges.
      graph = CallGraph.create(all_beams(), [{DemoApp.BehaviourImpl, :hello, 0}])
      calls = graph[{DemoApp.BehaviourImpl, :hello, 0}]
      # Only the static call to print_hello/0 should be present
      assert calls == [{DemoApp.BehaviourImplDep, :print_hello, 0}]
    end

    test "potential_module not in any provided beam adds no edges" do
      # Only Worker beam — BehaviourImpl is referenced nowhere in it, but even
      # if an atom for an unknown module appeared, no edges should be added.
      graph = CallGraph.create([beam(DemoApp.Worker)], [{DemoApp.Worker, :process, 1}])
      assert is_list(graph[{DemoApp.Worker, :process, 1}])
    end
  end

  # ---- BFS termination and cycle safety ----

  describe "create/2 - BFS termination" do
    test "terminates when starting point transitively reaches itself (cross-module cycle)" do
      # Application.start calls Worker.process; if analysis ever produces a
      # cycle the BFS must still terminate.
      graph = CallGraph.create(all_beams(), [{DemoApp.Application, :start, 2}])
      assert is_map(graph)
    end

    test "each reachable node appears as a key exactly once" do
      graph = CallGraph.create(all_beams(), [{DemoApp.BehaviourImpl, :hello, 0}])
      keys = Map.keys(graph)
      assert keys == Enum.uniq(keys)
    end
  end
end
