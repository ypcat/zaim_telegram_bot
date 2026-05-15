defmodule LedgerBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :ledger_bot,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        ledger_bot: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LedgerBot.Application, []}
    ]
  end

  defp deps do
    g = fn owner_repo, branch ->
      [git: "https://github.com/#{owner_repo}.git", branch: branch, override: true]
    end

    [
      # Bot
      {:ex_gram, g.("rockneurotiko/ex_gram", "master")},
      {:req, g.("wojtekmach/req", "main")},

      # JSON
      {:jason, g.("michalmuskala/jason", "master")},

      # Database
      {:ecto_sqlite3, g.("elixir-sqlite/ecto_sqlite3", "main")},
      {:exqlite, g.("elixir-sqlite/exqlite", "main")},
      {:ecto_sql, g.("elixir-ecto/ecto_sql", "master")},
      {:ecto, g.("elixir-ecto/ecto", "master")},
      {:decimal, g.("ericmj/decimal", "main")},
      {:db_connection, g.("elixir-ecto/db_connection", "master")},

      # HTTP (req/finch stack)
      {:finch, g.("sneako/finch", "main")},
      {:mint, g.("elixir-mint/mint", "main")},
      {:castore, g.("elixir-mint/castore", "main")},
      {:hpax, g.("elixir-mint/hpax", "main")},
      {:mime, g.("elixir-plug/mime", "master")},

      # Utilities
      {:telemetry, g.("beam-telemetry/telemetry", "main")},
      {:nimble_options, g.("dashbitco/nimble_options", "main")},
      {:nimble_pool, g.("dashbitco/nimble_pool", "main")},
      {:nimble_ownership, g.("dashbitco/nimble_ownership", "main")},

      # NIF build tools (exqlite)
      {:elixir_make, g.("elixir-lang/elixir_make", "master")},
      {:cc_precompiler, g.("cocoa-xu/cc_precompiler", "main")}
    ]
  end
end
