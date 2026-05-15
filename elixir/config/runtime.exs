import Config

if config_env() == :prod do
  token = System.fetch_env!("TELEGRAM_BOT_TOKEN")
  admin_id = System.fetch_env!("ADMIN_TELEGRAM_ID") |> String.to_integer()
  db_path = System.get_env("DATABASE_PATH", "/var/lib/ledger_bot/ledger.db")

  config :ex_gram, token: token

  config :ledger_bot,
    admin_telegram_id: admin_id

  config :ledger_bot, LedgerBot.Repo,
    database: db_path,
    journal_mode: :wal,
    busy_timeout: 2000,
    pool_size: 10
end

if config_env() in [:dev, :test] do
  if token = System.get_env("TELEGRAM_BOT_TOKEN") do
    config :ex_gram, token: token
  end

  config :ledger_bot,
    admin_telegram_id: System.get_env("ADMIN_TELEGRAM_ID", "0") |> String.to_integer()
end
