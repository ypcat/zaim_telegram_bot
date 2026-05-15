import Config

config :ledger_bot, LedgerBot.Repo,
  database: Path.expand("../dev.db", __DIR__),
  journal_mode: :wal,
  busy_timeout: 2000,
  pool_size: 5
