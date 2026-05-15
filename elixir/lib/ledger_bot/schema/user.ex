defmodule LedgerBot.Schema.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :telegram_id, :integer

    has_many :collaborators, LedgerBot.Schema.Collaborator
    has_many :account_books, through: [:collaborators, :account_book]
    has_many :owned_books, LedgerBot.Schema.AccountBook, foreign_key: :owner_id

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:telegram_id])
    |> validate_required([:telegram_id])
    |> unique_constraint(:telegram_id)
  end
end
