defmodule LedgerBot.Bot.Formatter do
  alias LedgerBot.Schema.Transaction

  def amount(minor_units), do: Transaction.amount_to_display(minor_units)

  def transaction_summary(data) do
    type_icon = if data[:type] == "income", do: "💰", else: "💸"
    cat = data[:category_name] || "?"
    subcat = if data[:subcategory_name], do: "/#{data[:subcategory_name]}", else: ""
    date = data[:date] || Date.utc_today()
    place = data[:place] || "?"
    amt = amount(data[:amount] || 0)
    note = if data[:note], do: "\n📝 #{data[:note]}", else: ""

    "#{type_icon} #{cat}#{subcat}  #{amt}\n🏪 #{place}  📅 #{date}#{note}"
  end

  def transaction_row(txn, idx) do
    cat = if txn.category, do: txn.category.name, else: "?"
    icon = if txn.category && txn.category.icon, do: "#{txn.category.icon} ", else: ""
    amt = amount(txn.amount)
    type_sign = if txn.type == "income", do: "+", else: "-"
    "#{idx}. #{txn.date} #{icon}#{cat} #{txn.place} #{type_sign}#{amt}"
  end

  def monthly_summary_text(summary, year, month) do
    expense = amount(summary.total_expense)
    income = amount(summary.total_income)

    cat_lines =
      summary.by_category
      |> Enum.filter(fn c -> c.type == "expense" end)
      |> Enum.sort_by(fn c -> -c.amount end)
      |> Enum.map(fn c ->
        icon = if c.icon, do: "#{c.icon} ", else: ""
        "  #{icon}#{c.name}：#{amount(c.amount)}"
      end)
      |> Enum.join("\n")

    """
    📅 *#{year}年#{month}月統計*

    💸 支出：#{expense}
    💰 收入：#{income}
    📊 淨額：#{amount(summary.total_income - summary.total_expense)}

    *支出明細：*
    #{cat_lines}
    """
  end

  def annual_summary_text(rows, year) do
    lines =
      rows
      |> Enum.map(fn r ->
        "#{r.month}　支：#{amount(r.expense)}　收：#{amount(r.income)}"
      end)
      |> Enum.join("\n")

    total_expense = Enum.reduce(rows, 0, fn r, acc -> acc + r.expense end)
    total_income  = Enum.reduce(rows, 0, fn r, acc -> acc + r.income  end)

    """
    📊 *#{year}年統計*

    #{lines}

    *全年合計*
    💸 支出：#{amount(total_expense)}
    💰 收入：#{amount(total_income)}
    """
  end
end
