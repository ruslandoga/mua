defmodule Mua.MixProject do
  use Mix.Project

  @version "0.2.5"
  @repo_url "https://github.com/ruslandoga/mua"

  def project do
    [
      app: :mua,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # hex
      package: package(),
      description: "Minimal SMTP client",
      # docs
      name: "Mua",
      docs: [
        source_url: @repo_url,
        source_ref: "v#{@version}",
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"],
        skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
      ],
      xref: [
        exclude: [
          {:public_key, :cacerts_get, 0}
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:ssl | extra_applications(Mix.env())]
    ]
  end

  defp extra_applications(env) when env in [:dev, :test], do: [:inets]
  defp extra_applications(_env), do: []

  def cli do
    [
      preferred_envs: [docs: :docs, "hex.publish": :docs, dialyzer: :static]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @repo_url}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:castore, "~> 0.1.0 or ~> 1.0", optional: true},
      {:dialyxir, "~> 1.3", only: :static, runtime: false},
      {:ex_doc, "~> 0.29", only: :docs},
      {:decimal, "~> 2.1", only: :test},
      {:jason, "~> 1.4", only: :test},
      {:mail, "~> 0.5.1", only: :test},
      {:benchee, "~> 1.3", only: :bench}
    ]
  end
end
