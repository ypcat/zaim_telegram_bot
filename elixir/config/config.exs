import Config

config :ex_gram, adapter: ExGram.Adapter.Req

config :ledger_bot, ecto_repos: [LedgerBot.Repo]

import_config "#{config_env()}.exs"
