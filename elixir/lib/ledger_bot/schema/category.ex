defmodule LedgerBot.Schema.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    field :type, :string
    field :icon, :string
    field :sort_order, :integer, default: 0

    belongs_to :account_book, LedgerBot.Schema.AccountBook
    belongs_to :parent, LedgerBot.Schema.Category
    has_many :subcategories, LedgerBot.Schema.Category, foreign_key: :parent_id

    timestamps()
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :type, :icon, :sort_order, :account_book_id, :parent_id])
    |> validate_required([:name, :type, :account_book_id])
    |> validate_inclusion(:type, ~w(expense income))
    |> validate_length(:name, max: 50)
  end
end
