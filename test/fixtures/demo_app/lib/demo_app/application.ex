defmodule DemoApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    result = DemoApp.Worker.process("hello")
    IO.puts("Worker result: #{result}")
    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
  end
end
