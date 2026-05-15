defmodule LedgerBot.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :account_book_id, references(:account_books), null: false
      add :parent_id, references(:categories)
      add :name, :string, null: false
      add :type, :string, null: false
      add :icon, :string
      add :sort_order, :integer, default: 0
      timestamps()
    end

    create index(:categories, [:account_book_id])
    create index(:categories, [:parent_id])
  end
end
