defmodule PhoenixKitDb.MixProject do
  use Mix.Project

  @version "0.1.1"
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
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitDb.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitDb.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      path when is_binary(path) and path != "" -> {app, [path: path, override: true] ++ opts}
      _ when opts == [] -> {app, requirement}
      _ -> {app, requirement, opts}
    end
  end

  defp deps do
    [
      # 1.7.55, not a bare `~> 1.7`: `fetch_row/3` calls
      # `PhoenixKit.RepoHelper.get_pk_column/1` unguarded, which core first
      # shipped in 1.7.55. `~> 1.7` admits 1.7.0, where that function — and
      # `PhoenixKit.Module` (1.7.46) and `Dashboard.Tab`'s `live_view` field
      # (1.7.46) — don't exist yet. `PhoenixKit.Activity` (1.7.90) is *not* in
      # the floor: that call is behind `Code.ensure_loaded?/1`, so an older
      # core just skips the log.
      pk_dep(:phoenix_kit, "~> 1.7.55"),
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
