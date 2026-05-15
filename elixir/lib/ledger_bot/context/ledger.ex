defmodule LedgerBot.Context.Ledger do
  import Ecto.Query
  alias LedgerBot.Repo
  alias LedgerBot.Schema.Transaction

  def add(attrs) do
    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
  end

  def list_recent(book_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    offset = Keyword.get(opts, :offset, 0)

    from(t in Transaction,
      where: t.account_book_id == ^book_id and is_nil(t.deleted_at),
      order_by: [desc: t.date, desc: t.inserted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:category, :subcategory, :user]
    )
    |> Repo.all()
  end

  def count_active(book_id) do
    Repo.one(from t in Transaction, where: t.account_book_id == ^book_id and is_nil(t.deleted_at), select: count())
  end

  def get_for_user(txn_id, book_id) do
    Repo.get_by(Transaction, id: txn_id, account_book_id: book_id, deleted_at: nil)
  end

  def update(txn, attrs) do
    txn |> Transaction.changeset(attrs) |> Repo.update()
  end

  def soft_delete(txn) do
    txn |> Transaction.soft_delete_changeset() |> Repo.update()
  end

  def monthly_summary(book_id, year, month) do
    start_date = Date.new!(year, month, 1) |> Date.to_iso8601()
    end_date = Date.new!(year, month, Date.days_in_month(Date.new!(year, month, 1))) |> Date.to_iso8601()

    rows =
      from(t in Transaction,
        where: t.account_book_id == ^book_id and is_nil(t.deleted_at)
          and t.date >= ^start_date and t.date <= ^end_date,
        join: c in assoc(t, :category),
        group_by: [t.type, c.id, c.name, c.icon],
        select: {t.type, c.name, c.icon, sum(t.amount)}
      )
      |> Repo.all()

    total_expense =
      rows
      |> Enum.filter(fn {type, _, _, _} -> type == "expense" end)
      |> Enum.reduce(0, fn {_, _, _, amt}, acc -> acc + amt end)

    total_income =
      rows
      |> Enum.filter(fn {type, _, _, _} -> type == "income" end)
      |> Enum.reduce(0, fn {_, _, _, amt}, acc -> acc + amt end)

    by_category =
      rows
      |> Enum.map(fn {type, name, icon, amt} -> %{type: type, name: name, icon: icon, amount: amt} end)

    %{total_expense: total_expense, total_income: total_income, by_category: by_category}
  end

  def annual_summary(book_id, year) do
    start_date = "#{year}-01-01"
    end_date = "#{year}-12-31"

    rows =
      from(t in Transaction,
        where: t.account_book_id == ^book_id and is_nil(t.deleted_at)
          and t.date >= ^start_date and t.date <= ^end_date,
        group_by: [t.type, fragment("substr(?, 1, 7)", t.date)],
        select: {t.type, fragment("substr(?, 1, 7)", t.date), sum(t.amount)}
      )
      |> Repo.all()

    rows
    |> Enum.group_by(fn {_, month, _} -> month end)
    |> Enum.map(fn {month, entries} ->
      expense = entries |> Enum.filter(fn {t, _, _} -> t == "expense" end) |> Enum.reduce(0, fn {_, _, a}, acc -> acc + a end)
      income  = entries |> Enum.filter(fn {t, _, _} -> t == "income"  end) |> Enum.reduce(0, fn {_, _, a}, acc -> acc + a end)
      %{month: month, expense: expense, income: income}
    end)
    |> Enum.sort_by(& &1.month)
  end
end
