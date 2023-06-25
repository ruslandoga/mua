defmodule Mua.MixProject do
  use Mix.Project

  def project do
    [
      app: :mua,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:castore, "~> 1.0"},
      {:bamboo, "~> 2.3", optional: true},
      {:swoosh, "~> 1.11", optional: true},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end
end
