defmodule Treeshake.CallGraphTest do
  use ExUnit.Case, async: true

  setup_all do
    graph = Treeshake.build_call_graph(project: "test/fixtures/demo_app")
    # File.write!("test/fixtures/call_graph.bin", :erlang.term_to_binary(graph))
    {:ok, graph: graph}
  end

  # ---- graph keys and reachability ----

  describe "build_call_graph/1 - graph keys and reachability" do
    test "entry point is included as a key", %{graph: graph} do
      assert Map.has_key?(graph, {DemoApp.Application, :start, 2})
    end

    test "function reachable from entry point is added as a key", %{graph: graph} do
      assert Map.has_key?(graph, {DemoApp.BehaviourImplDep, :print_hello, 0})
    end

    test "unreachable public function is not included in the graph", %{graph: graph} do
      # Worker.unused/1 is public but never called from any reachable path
      refute Map.has_key?(graph, {DemoApp.Worker, :unused, 1})
    end
  end

  # ---- call values and external references ----

  describe "build_call_graph/1 - call values" do
    test "private helper calls are expanded into the public function's call list", %{graph: graph} do
      # Worker.process/1 -> private upcase/1 -> String.upcase/1
      calls = graph[{DemoApp.Worker, :process, 1}]
      assert {String, :upcase, 1} in calls
    end

    test "call list for a reachable callee is also populated", %{graph: graph} do
      # BehaviourImplDep.print_hello/0 calls IO.puts/2 which is external
      calls = graph[{DemoApp.BehaviourImplDep, :print_hello, 0}]
      assert is_list(calls)
      assert Enum.any?(calls, fn {m, _, _} -> m == IO end)
    end

    test "call lists contain no duplicates", %{graph: graph} do
      for {_mfa, calls} <- graph do
        assert calls == Enum.uniq(calls)
      end
    end
  end

  # ---- behaviour edges ----

  describe "build_call_graph/1 - behaviour edges" do
    test "potential_module implementing a behaviour adds callback edges to the call list",
         %{graph: graph} do
      # Application.start/2 passes DemoApp.BehaviourImpl as an atom argument,
      # so it appears in potential_modules. DemoApp.BehaviourImpl implements
      # DemoApp.Behaviour which declares hello/0 as a callback.
      # => {DemoApp.BehaviourImpl, :hello, 0} must appear in start/2's call list.
      calls = graph[{DemoApp.Application, :start, 2}]
      assert {DemoApp.BehaviourImpl, :hello, 0} in calls
    end

    test "callback implementation is reachable via BFS through the behaviour edge",
         %{graph: graph} do
      assert Map.has_key?(graph, {DemoApp.BehaviourImpl, :hello, 0})
    end

    test "potential_module not implementing any behaviour adds no extra edges", %{graph: graph} do
      # BehaviourImpl.hello/0 only calls print_hello/0 — no extra behaviour edges
      calls = graph[{DemoApp.BehaviourImpl, :hello, 0}]
      assert calls == [{DemoApp.BehaviourImplDep, :print_hello, 0}]
    end
  end

  # ---- BFS termination and cycle safety ----

  describe "build_call_graph/1 - BFS termination" do
    test "terminates and returns a map", %{graph: graph} do
      assert is_map(graph)
    end

    test "each reachable node appears as a key exactly once", %{graph: graph} do
      keys = Map.keys(graph)
      assert keys == Enum.uniq(keys)
    end
  end

  @tag :cg_fixture
  test "verify graph against fixture", %{graph: graph} do
    fixture =
      File.read!("test/fixtures/call_graph.bin")
      |> :erlang.binary_to_term()

    assert fixture == graph
  end
end
