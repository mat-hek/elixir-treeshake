defmodule :treeshake_helper do
  def start(apps) do
    apps = parse_apps(apps)

    case :application.ensure_all_started(apps) do
      {:ok, _apps} ->
        :erlang.halt(0)

      error ->
        :erlang.display(error)
        :erlang.halt(1)
    end
  end

  defp parse_apps([]), do: []
  defp parse_apps([h | t]), do: [:erlang.list_to_atom(h) | parse_apps(t)]

  def raise_treeshaked_error(m, f, a) do
    try do
      :erlang.error(:get_stacktrace)
    rescue
      _e ->
        :erlang.display(%{
          error: :function_treeshaked,
          function: {m, f, a},
          stacktrace: __STACKTRACE__
        })
    end

    raise "TreeshakedError"
  end
end
