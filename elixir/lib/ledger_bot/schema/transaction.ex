defmodule LedgerBot.Schema.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transactions" do
    field :type, :string
    field :amount, :integer
    field :currency, :string
    field :place, :string
    field :note, :string
    field :date, :string
    field :deleted_at, :string

    belongs_to :account_book, LedgerBot.Schema.AccountBook
    belongs_to :user, LedgerBot.Schema.User
    belongs_to :category, LedgerBot.Schema.Category
    belongs_to :subcategory, LedgerBot.Schema.Category, foreign_key: :subcategory_id

    timestamps()
  end

  def changeset(txn, attrs) do
    txn
    |> cast(attrs, [:type, :amount, :currency, :place, :note, :date,
                    :account_book_id, :user_id, :category_id, :subcategory_id])
    |> validate_required([:type, :amount, :place, :date, :account_book_id, :user_id, :category_id])
    |> validate_inclusion(:type, ~w(expense income))
    |> validate_number(:amount, greater_than: 0, less_than_or_equal_to: 99_999_999)
    |> validate_length(:place, max: 100)
  end

  def soft_delete_changeset(txn) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    change(txn, deleted_at: now)
  end

  def amount_to_display(minor_units) when is_integer(minor_units) do
    whole = div(minor_units, 100)
    frac = rem(minor_units, 100)
    "#{whole}.#{String.pad_leading(Integer.to_string(frac), 2, "0")}"
  end

  def amount_from_string(str) when is_binary(str) do
    case Float.parse(str) do
      {val, ""} when val > 0 -> {:ok, round(val * 100)}
      _ -> :error
    end
  end
end
