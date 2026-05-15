defmodule LedgerBot.Schema.Collaborator do
  use Ecto.Schema
  import Ecto.Changeset

  schema "collaborators" do
    belongs_to :user, LedgerBot.Schema.User
    belongs_to :account_book, LedgerBot.Schema.AccountBook

    timestamps()
  end

  def changeset(collab, attrs) do
    collab
    |> cast(attrs, [:user_id, :account_book_id])
    |> validate_required([:user_id, :account_book_id])
    |> unique_constraint([:user_id, :account_book_id])
  end
end
