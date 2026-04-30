defmodule Treeshake.MixProject do
  use Mix.Project

  def project do
    [
      app: :treeshake,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    # :tools provides :xref (used as fallback when dialyzer is unavailable)
    [extra_applications: [:logger, :tools]]
  end

  defp aliases() do
    [
      "test.reshot": [fn _args -> Application.put_env(:treeshake, :resnapshot, true) end, "test"]
    ]
  end

  def cli do
    [
      preferred_envs: ["test.reshot": :test]
    ]
  end

  defp deps do
    [
      {:async_test, github: "software-mansion-labs/elixir_async_test", only: :test}
    ]
  end
end
