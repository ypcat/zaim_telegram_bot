defmodule LedgerBot.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :user_id, references(:users), null: false
      add :chat_id, :integer, null: false
      add :state, :string, null: false, default: "idle"
      add :data, :string, null: false, default: "{}"
      add :active_book_id, references(:account_books)
      add :expires_at, :string, null: false
      timestamps()
    end

    create unique_index(:sessions, [:user_id, :chat_id])
  end
end
