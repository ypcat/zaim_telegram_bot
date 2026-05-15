defmodule LedgerBot.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :account_book_id, references(:account_books), null: false
      add :user_id, references(:users), null: false
      add :category_id, references(:categories), null: false
      add :subcategory_id, references(:categories)
      add :type, :string, null: false
      add :amount, :integer, null: false
      add :currency, :string
      add :place, :string, null: false
      add :note, :string
      add :date, :string, null: false
      add :deleted_at, :string
      timestamps()
    end

    create index(:transactions, [:account_book_id, :date])
    create index(:transactions, [:account_book_id, :category_id])
  end
end
