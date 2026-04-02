defmodule DemoApp.Behaviour do
  @callback hello() :: :ok

  def call_hello(module) do
    module.hello()
  end
end
