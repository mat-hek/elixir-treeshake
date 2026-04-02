defmodule DemoApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    {:ok, sup} = Supervisor.start_link([HelloPopcorn], strategy: :one_for_one, name: __MODULE__)
    result = DemoApp.Worker.process("hello")
    IO.puts("Worker result: #{result}")
    DemoApp.Behaviour.call_hello(DemoApp.BehaviourImpl)
    {:ok, sup}
  end
end
