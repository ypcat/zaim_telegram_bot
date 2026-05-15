defmodule LedgerBot.Context.Users do
  alias LedgerBot.Repo
  alias LedgerBot.Schema.User

  def get_or_create(telegram_id) do
    case Repo.get_by(User, telegram_id: telegram_id) do
      nil ->
        %User{}
        |> User.changeset(%{telegram_id: telegram_id})
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  def get_by_telegram_id(telegram_id) do
    Repo.get_by(User, telegram_id: telegram_id)
  end
end
