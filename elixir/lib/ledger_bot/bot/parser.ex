defmodule LedgerBot.Bot.Parser do
  @aliases %{
    "食物" => "飲食", "吃飯" => "飲食", "早餐" => "飲食", "午餐" => "飲食",
    "晚餐" => "飲食", "點心" => "飲食", "咖啡" => "飲食", "飲料" => "飲食",
    "買菜" => "雜貨", "超市" => "雜貨", "藥妝" => "雜貨",
    "車費" => "交通", "電車" => "交通", "公車" => "交通", "計程車" => "交通", "捷運" => "交通",
    "手機" => "通訊", "行動" => "通訊", "網路" => "通訊",
    "水費" => "水電", "電費" => "水電",
    "房租" => "住居", "房子" => "住居",
    "聚餐" => "交際", "禮物" => "交際",
    "電影" => "娛樂", "遊戲" => "娛樂", "書" => "娛樂", "書籍" => "娛樂",
    "學費" => "教育", "補習" => "教育",
    "藥" => "醫療", "掛號" => "醫療",
    "衣服" => "服飾", "剪髮" => "服飾", "鞋子" => "服飾",
    "油費" => "汽車", "停車" => "汽車",
    "稅" => "稅務",
    "轉帳" => "其他",
    "薪水" => "薪水", "薪資" => "薪水"
  }

  @categories Map.keys(@aliases) ++ Map.values(@aliases) |> Enum.uniq()
  @compiled_pattern Regex.compile!(
    "^(\\d{8})?\\s*(" <>
      Enum.join(Enum.sort_by(@categories, &{-byte_size(&1), &1}), "|") <>
      ")\\s+(.+?)\\s+(\\d+(?:\\.\\d+)?)元?$",
    "u"
  )

  def parse(text) do
    case Regex.run(@compiled_pattern, String.trim(text)) do
      [_, date_str, alias_matched, place, amount_str] ->
        canonical = Map.get(@aliases, alias_matched, alias_matched)
        type = if canonical in ["薪水", "獎金", "收款"], do: "income", else: "expense"

        amount_minor =
          case Float.parse(amount_str) do
            {val, ""} -> round(val * 100)
            _ -> nil
          end

        date =
          case date_str do
            "" -> nil
            d when byte_size(d) == 8 ->
              case Date.from_iso8601("#{String.slice(d, 0, 4)}-#{String.slice(d, 4, 2)}-#{String.slice(d, 6, 2)}") do
                {:ok, date} -> date
                _ -> nil
              end
          end

        if amount_minor && amount_minor > 0 do
          {:ok, %{
            type: type,
            category_name: canonical,
            alias_matched: alias_matched,
            place: String.trim(place),
            amount: amount_minor,
            date: date
          }}
        else
          :error
        end

      _ ->
        :error
    end
  end

  def aliases, do: @aliases
  def category_names, do: @categories
end
