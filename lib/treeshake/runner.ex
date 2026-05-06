defmodule :treeshake_boot do
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
end
