defmodule LedgerBot.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :telegram_id, :integer, null: false
      timestamps()
    end

    create unique_index(:users, [:telegram_id])
  end
end
