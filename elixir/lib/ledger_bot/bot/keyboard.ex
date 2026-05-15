defmodule LedgerBot.Bot.Keyboard do
  import ExGram.Dsl.Keyboard, only: [inline_button: 2]

  @page_size 8

  def type_buttons do
    ExGram.Dsl.create_inline_keyboard([
      [btn("💸 支出", "type:expense"), btn("💰 收入", "type:income")],
      [btn("❌ 取消", "cancel")]
    ])
  end

  def category_grid_paged(categories, page, type_prefix \\ "cat") do
    total = length(categories)
    total_pages = max(1, div(total + @page_size - 1, @page_size))
    page = min(max(page, 1), total_pages)

    rows =
      categories
      |> Enum.slice((page - 1) * @page_size, @page_size)
      |> Enum.chunk_every(2)
      |> Enum.map(fn row ->
        Enum.map(row, fn cat ->
          label = if cat.icon, do: "#{cat.icon} #{cat.name}", else: cat.name
          btn(label, "#{type_prefix}:#{cat.id}")
        end)
      end)

    nav = nav_row(page, total_pages, "cat_page")
    extras = if nav == [], do: [], else: [nav]
    ExGram.Dsl.create_inline_keyboard(rows ++ extras ++ [[btn("❌ 取消", "cancel")]])
  end

  def subcategory_grid(subcats, _parent_id) do
    rows =
      subcats
      |> Enum.chunk_every(2)
      |> Enum.map(fn row ->
        Enum.map(row, fn cat -> btn(cat.name, "subcat:#{cat.id}") end)
      end)

    ExGram.Dsl.create_inline_keyboard(rows ++ [[btn("⏭ 略過", "subcat:skip"), btn("❌ 取消", "cancel")]])
  end

  def date_buttons do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    ExGram.Dsl.create_inline_keyboard([
      [btn("今天", "date:#{today}"), btn("昨天", "date:#{yesterday}")],
      [btn("❌ 取消", "cancel")]
    ])
  end

  def confirm_buttons do
    ExGram.Dsl.create_inline_keyboard([
      [btn("✅ 確認", "confirm:yes"), btn("❌ 取消", "cancel")],
      [btn("✏️ 金額", "edit_field:amount"), btn("✏️ 分類", "edit_field:category"),
       btn("✏️ 地點", "edit_field:place"), btn("✏️ 日期", "edit_field:date")]
    ])
  end

  def cancel_button do
    ExGram.Dsl.create_inline_keyboard([[btn("❌ 取消", "cancel")]])
  end

  def recent_entries_row(recents) do
    buttons = Enum.map(recents, fn %{category_name: cat, place: place} ->
      btn("#{cat}/#{place}", "quick:#{cat}:#{place}")
    end)
    if Enum.empty?(buttons), do: nil, else: ExGram.Dsl.create_inline_keyboard([buttons])
  end

  defp nav_row(page, total_pages, prefix) when total_pages > 1 do
    prev = if page > 1, do: [btn("◀", "#{prefix}:#{page - 1}")], else: []
    info = [btn("#{page}/#{total_pages}", "noop")]
    next = if page < total_pages, do: [btn("▶", "#{prefix}:#{page + 1}")], else: []
    prev ++ info ++ next
  end

  defp nav_row(_, _, _), do: []

  defp btn(text, callback_data), do: inline_button(text, callback_data: callback_data)
end
