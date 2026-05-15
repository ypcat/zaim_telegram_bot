defmodule LedgerBot.Repo do
  use Ecto.Repo,
    otp_app: :ledger_bot,
    adapter: Ecto.Adapters.SQLite3
end
