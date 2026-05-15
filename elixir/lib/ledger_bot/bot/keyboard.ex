defmodule LedgerBot.Bot.Keyboard do
  import ExGram.Dsl.Keyboard, only: [inline_button: 2]

  def type_buttons do
    ExGram.Dsl.create_inline_keyboard([
      [btn("💸 支出", "type:expense"), btn("💰 收入", "type:income")],
      [btn("❌ 取消", "cancel")]
    ])
  end

  def category_grid(categories, type_prefix \\ "cat") do
    rows =
      categories
      |> Enum.chunk_every(4)
      |> Enum.map(fn row ->
        Enum.map(row, fn cat ->
          label = if cat.icon, do: "#{cat.icon} #{cat.name}", else: cat.name
          btn(label, "#{type_prefix}:#{cat.id}")
        end)
      end)

    ExGram.Dsl.create_inline_keyboard(rows ++ [[btn("❌ 取消", "cancel")]])
  end

  def subcategory_grid(subcats, _parent_id) do
    rows =
      subcats
      |> Enum.chunk_every(4)
      |> Enum.map(fn row ->
        Enum.map(row, fn cat -> btn(cat.name, "subcat:#{cat.id}") end)
      end)

    skip_row = [btn("⏭ 略過", "subcat:skip"), btn("❌ 取消", "cancel")]
    ExGram.Dsl.create_inline_keyboard(rows ++ [skip_row])
  end

  def numpad(current_amount) do
    display = if current_amount == "", do: "0", else: current_amount

    ExGram.Dsl.create_inline_keyboard([
      [btn("7", "num:7"), btn("8", "num:8"), btn("9", "num:9")],
      [btn("4", "num:4"), btn("5", "num:5"), btn("6", "num:6")],
      [btn("1", "num:1"), btn("2", "num:2"), btn("3", "num:3")],
      [btn(".", "num:."), btn("0", "num:0"), btn("⌫", "num:back")],
      [btn("✓ #{display}", "num:confirm")]
    ])
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
      [btn("✏️ 改金額", "edit_field:amount"), btn("✏️ 改分類", "edit_field:category")],
      [btn("✏️ 改地點", "edit_field:place"), btn("✏️ 改日期", "edit_field:date")]
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

  def pagination(page, total_pages, prefix) do
    prev = if page > 1, do: [btn("◀", "#{prefix}:#{page - 1}")], else: []
    info = [btn("#{page}/#{total_pages}", "noop")]
    next = if page < total_pages, do: [btn("▶", "#{prefix}:#{page + 1}")], else: []
    ExGram.Dsl.create_inline_keyboard([prev ++ info ++ next])
  end

  defp btn(text, callback_data), do: inline_button(text, callback_data: callback_data)
end
