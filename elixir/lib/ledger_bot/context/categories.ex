defmodule LedgerBot.Context.Categories do
  import Ecto.Query
  alias LedgerBot.Repo
  alias LedgerBot.Schema.Category

  def list_parents(book_id, type \\ nil) do
    query =
      from c in Category,
        where: c.account_book_id == ^book_id and is_nil(c.parent_id),
        order_by: [asc: c.sort_order, asc: c.name]

    query =
      if type, do: where(query, [c], c.type == ^type), else: query

    Repo.all(query)
  end

  def list_subcategories(parent_id) do
    from(c in Category,
      where: c.parent_id == ^parent_id,
      order_by: [asc: c.sort_order, asc: c.name]
    )
    |> Repo.all()
  end

  def get(category_id), do: Repo.get(Category, category_id)

  def find_by_name(book_id, name) do
    Repo.get_by(Category, account_book_id: book_id, name: name, parent_id: nil)
  end

  def create(attrs), do: %Category{} |> Category.changeset(attrs) |> Repo.insert()

  def delete(category_id, book_id) do
    case Repo.get_by(Category, id: category_id, account_book_id: book_id) do
      nil -> {:error, :not_found}
      cat -> Repo.delete(cat)
    end
  end

  def seed_defaults(book_id) do
    defaults = default_categories()

    Repo.transaction(fn ->
      Enum.each(defaults, fn {type, parents} ->
        Enum.with_index(parents, fn {name, icon, subs}, idx ->
          {:ok, parent} =
            %Category{}
            |> Category.changeset(%{
              account_book_id: book_id,
              name: name,
              type: type,
              icon: icon,
              sort_order: idx
            })
            |> Repo.insert()

          Enum.with_index(subs, fn sub_name, sidx ->
            %Category{}
            |> Category.changeset(%{
              account_book_id: book_id,
              parent_id: parent.id,
              name: sub_name,
              type: type,
              sort_order: sidx
            })
            |> Repo.insert!()
          end)
        end)
      end)
    end)
  end

  defp default_categories do
    %{
      "expense" => [
        {"飲食", "🍽️", ["早餐", "午餐", "晚餐", "點心", "咖啡", "飲料"]},
        {"雜貨", "🛒", ["超市", "藥妝", "生活用品"]},
        {"交通", "🚌", ["電車", "公車", "計程車", "機票", "停車"]},
        {"通訊", "📱", ["手機", "網路", "電話"]},
        {"水電", "💡", ["水費", "電費", "瓦斯"]},
        {"住居", "🏠", ["房租", "管理費", "修繕"]},
        {"交際", "🎉", ["聚餐", "禮物", "婚禮"]},
        {"娛樂", "🎮", ["電影", "遊戲", "書籍", "音樂"]},
        {"教育", "📚", ["學費", "補習", "書籍"]},
        {"醫療", "🏥", ["掛號", "藥費", "健康食品"]},
        {"服飾", "👕", ["衣服", "鞋子", "配件", "剪髮"]},
        {"汽車", "🚗", ["油費", "保養", "保險", "停車"]},
        {"稅務", "📋", ["所得稅", "健保", "勞保"]},
        {"大型支出", "💰", ["電器", "家具", "旅遊"]},
        {"其他", "📌", []}
      ],
      "income" => [
        {"薪水", "💼", ["本薪", "加班費", "獎金"]},
        {"獎金", "🎁", []},
        {"收款", "💸", ["轉帳收入", "還款"]}
      ]
    }
  end
end
