defmodule LedgerBot.Context.Books do
  import Ecto.Query
  alias LedgerBot.Repo
  alias LedgerBot.Schema.{AccountBook, Collaborator}

  def list_for_user(user_id) do
    from(b in AccountBook,
      join: c in Collaborator, on: c.account_book_id == b.id,
      where: c.user_id == ^user_id,
      order_by: [asc: b.inserted_at]
    )
    |> Repo.all()
  end

  def get_book_for_user(book_id, user_id) do
    from(b in AccountBook,
      join: c in Collaborator, on: c.account_book_id == b.id,
      where: b.id == ^book_id and c.user_id == ^user_id
    )
    |> Repo.one()
  end

  def create(attrs, user_id) do
    Repo.transaction(fn ->
      book =
        %AccountBook{}
        |> AccountBook.changeset(Map.put(attrs, :owner_id, user_id))
        |> Repo.insert!()

      %Collaborator{}
      |> Collaborator.changeset(%{user_id: user_id, account_book_id: book.id})
      |> Repo.insert!()

      book
    end)
  end

  def add_collaborator(book_id, user_id) do
    %Collaborator{}
    |> Collaborator.changeset(%{user_id: user_id, account_book_id: book_id})
    |> Repo.insert(on_conflict: :nothing)
  end

  def is_owner?(book_id, user_id) do
    Repo.exists?(from b in AccountBook, where: b.id == ^book_id and b.owner_id == ^user_id)
  end

  def is_collaborator?(book_id, user_id) do
    Repo.exists?(from c in Collaborator, where: c.account_book_id == ^book_id and c.user_id == ^user_id)
  end
end
