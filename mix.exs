defmodule Treeshake.MixProject do
  use Mix.Project

  def project do
    [
      app: :treeshake,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    # :tools provides :xref (used as fallback when dialyzer is unavailable)
    [extra_applications: [:logger, :tools]]
  end

  defp deps do
    []
  end
end
