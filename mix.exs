defmodule Mua.MixProject do
  use Mix.Project

  @version "0.2.1"
  @repo_url "https://github.com/ruslandoga/mua"

  def project do
    [
      app: :mua,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # dialyxir
      dialyzer: [
        plt_add_apps: [:castore]
      ],
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
      extra_applications: [:ssl]
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
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29", only: :dev},
      {:req, "~> 0.5.0", only: :test}
    ]
  end
end
