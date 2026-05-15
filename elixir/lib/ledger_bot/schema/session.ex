defmodule LedgerBot.Schema.Session do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sessions" do
    field :chat_id, :integer
    field :state, :string, default: "idle"
    field :data, :map, default: %{}
    field :expires_at, :string

    belongs_to :user, LedgerBot.Schema.User
    belongs_to :active_book, LedgerBot.Schema.AccountBook

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:chat_id, :state, :data, :expires_at, :user_id, :active_book_id])
    |> validate_required([:chat_id, :user_id])
    |> unique_constraint([:user_id, :chat_id])
  end
end
