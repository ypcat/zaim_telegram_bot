defmodule Mix.Tasks.Ledger.ImportZaim do
  use Mix.Task

  @shortdoc "Import transactions from a Zaim CSV export"

  @moduledoc """
  Imports transactions from a Zaim CSV export file.

      mix ledger.import_zaim FILE [--book BOOK_ID] [--dry-run]

  The CSV format is the output of dump.py: date,place,amount
  (tab-separated, with optional category column)
  """

  alias LedgerBot.Context.{Users, Books, Ledger, Categories}

  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, strict: [book: :integer, dry_run: :boolean])
    file = List.first(positional)
    book_id = opts[:book]
    dry_run = opts[:dry_run] || false

    unless file, do: Mix.raise("Usage: mix ledger.import_zaim FILE [--book ID] [--dry-run]")
    unless File.exists?(file), do: Mix.raise("File not found: #{file}")
    unless book_id, do: Mix.raise("--book BOOK_ID is required")

    admin_id = Application.get_env(:ledger_bot, :admin_telegram_id)
    user = Users.get_by_telegram_id(admin_id)
    unless user, do: Mix.raise("Admin user not found (ADMIN_TELEGRAM_ID=#{admin_id}). Run seeds first.")
    unless Books.is_collaborator?(book_id, user.id), do: Mix.raise("User has no access to book #{book_id}")

    lines = File.read!(file) |> String.split("\n", trim: true)
    IO.puts("Found #{length(lines)} lines in #{file}")

    {ok, skipped} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {line, lineno}, {ok, skip} ->
        case parse_line(line) do
          {:ok, row} ->
            cat = Categories.find_by_name(book_id, row.category) ||
                  Categories.find_by_name(book_id, "其他")

            if cat do
              attrs = %{
                account_book_id: book_id,
                user_id: user.id,
                category_id: cat.id,
                type: "expense",
                amount: row.amount,
                place: row.place,
                date: row.date
              }

              unless dry_run do
                case Ledger.add(attrs) do
                  {:ok, _} -> :ok
                  {:error, e} -> IO.puts("  Line #{lineno} insert error: #{inspect(e)}")
                end
              else
                IO.puts("  [dry-run] #{row.date} #{row.place} #{row.amount} -> #{cat.name}")
              end

              {ok + 1, skip}
            else
              IO.puts("  Line #{lineno} skipped: no category match for #{row.category}")
              {ok, skip + 1}
            end

          :error ->
            IO.puts("  Line #{lineno} skipped: parse error (#{line})")
            {ok, skip + 1}
        end
      end)

    mode = if dry_run, do: "[DRY RUN] ", else: ""
    IO.puts("#{mode}Done: #{ok} imported, #{skipped} skipped.")
  end

  defp parse_line(line) do
    parts = String.split(line, "\t")

    case parts do
      [date_str, place, amount_str | rest] ->
        category = List.first(rest, "其他")
        with {:ok, date} <- Date.from_iso8601(date_str),
             {amount_float, ""} <- Float.parse(amount_str),
             amount when amount > 0 <- round(amount_float * 100) do
          {:ok, %{date: Date.to_iso8601(date), place: place, amount: amount, category: category}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
