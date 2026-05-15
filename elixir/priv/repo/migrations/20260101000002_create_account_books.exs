defmodule LedgerBot.Repo.Migrations.CreateAccountBooks do
  use Ecto.Migration

  def change do
    create table(:account_books) do
      add :name, :string, null: false
      add :currency, :string, null: false, default: "TWD"
      add :owner_id, references(:users), null: false
      timestamps()
    end
  end
end
