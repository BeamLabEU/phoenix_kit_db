defmodule PhoenixKitDb.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_db"

  def project do
    [
      app: :phoenix_kit_db,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Database explorer module for PhoenixKit — browse tables, preview rows, and watch live mutations.",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Docs
      name: "PhoenixKitDb",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: ["compile", "quality"],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitDb.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitDb.Test.Repo",
        "test.setup"
      ]
    ]
  end

  defp deps do
    [
      {:phoenix_kit, "~> 1.7"},
      {:phoenix_live_view, "~> 1.1"},

      # Postgrex.Notifications drives the live-update Listener.
      {:postgrex, "~> 0.17"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitDb",
      source_ref: "v#{@version}"
    ]
  end
end
