defmodule LedgerBot.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    token = Application.get_env(:ex_gram, :token)

    children =
      [
        LedgerBot.Repo,
        {Finch, name: LedgerBot.Finch},
        LedgerBot.Bot.FSM
      ] ++
        if token do
          [ExGram, {LedgerBot.Bot.Handler, [method: :polling, token: token]}]
        else
          []
        end

    opts = [strategy: :one_for_one, name: LedgerBot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
