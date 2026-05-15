defmodule LedgerBot.Repo.Migrations.CreateCollaborators do
  use Ecto.Migration

  def change do
    create table(:collaborators) do
      add :user_id, references(:users), null: false
      add :account_book_id, references(:account_books), null: false
      timestamps()
    end

    create unique_index(:collaborators, [:user_id, :account_book_id])
  end
end
