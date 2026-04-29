defmodule Treeshake.TreeshakedError do
  @moduledoc """
  Exception raised at runtime by stub functions injected by Treeshake.

  When `stub_removed_public: true` is passed to `BeamRewriter.keep_funs/3`,
  removed public functions are replaced with stubs that raise this exception,
  making it obvious at runtime which functions were tree-shaken away.
  """

  defexception [:module, :function, :arity]

  @impl true
  def message(%{module: mod, function: fun, arity: arity}) do
    "#{inspect(mod)}.#{fun}/#{arity} was removed by Treeshake"
  end

  @doc false
  def trigger(module, function, arity) do
    # :erlang.display("Error: #{message(%{module: module, function: function, arity: arity})}")
    # Process.sleep(1000)
    raise __MODULE__, module: module, function: function, arity: arity
  end
end
