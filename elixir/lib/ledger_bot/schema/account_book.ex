defmodule LedgerBot.Schema.AccountBook do
  use Ecto.Schema
  import Ecto.Changeset

  schema "account_books" do
    field :name, :string
    field :currency, :string, default: "TWD"

    belongs_to :owner, LedgerBot.Schema.User
    has_many :collaborators, LedgerBot.Schema.Collaborator
    has_many :categories, LedgerBot.Schema.Category
    has_many :transactions, LedgerBot.Schema.Transaction

    timestamps()
  end

  def changeset(book, attrs) do
    book
    |> cast(attrs, [:name, :currency, :owner_id])
    |> validate_required([:name, :owner_id])
    |> validate_length(:name, max: 100)
  end
end
