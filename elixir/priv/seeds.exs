alias LedgerBot.Context.{Books, Users, Categories}

admin_id = Application.get_env(:ledger_bot, :admin_telegram_id, 0)

if admin_id > 0 do
  {:ok, user} = Users.get_or_create(admin_id)
  books = Books.list_for_user(user.id)

  if Enum.empty?(books) do
    {:ok, book} = Books.create(%{name: "個人帳本", currency: "TWD"}, user.id)
    Categories.seed_defaults(book.id)
    IO.puts("Seeded default categories for book: #{book.name}")
  else
    IO.puts("User already has books, skipping seed.")
  end
else
  IO.puts("ADMIN_TELEGRAM_ID not set; skipping seed.")
end
