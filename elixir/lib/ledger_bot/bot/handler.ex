defmodule LedgerBot.Bot.Handler do
  @moduledoc "ExGram bot handler: dispatches messages and callbacks to command modules."

  use ExGram.Bot, name: :ledger_bot, setup_commands: true

  alias LedgerBot.Bot.{FSM, Parser, Keyboard, Formatter}
  alias LedgerBot.Context.{Users, Books, Ledger, Categories}

  # ── Commands ──────────────────────────────────────────────────────────────

  command("start",      description: "👋 開始使用")
  command("add",        description: "➕ 新增記帳")
  command("list",       description: "📋 查看記錄")
  command("edit",       description: "✏️ 編輯記錄")
  command("delete",     description: "🗑️ 刪除記錄")
  command("month",      description: "📅 本月統計")
  command("year",       description: "📊 年度統計")
  command("books",      description: "📚 帳本管理")
  command("invite",     description: "🔗 邀請成員")
  command("categories", description: "🏷️ 分類管理")
  command("help",       description: "❓ 說明")

  # ── Text message handler ───────────────────────────────────────────────────

  def handle({:text, text, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    session = FSM.get(user_id, chat_id)

    case session.fsm_state do
      "idle" ->
        case Parser.parse(text) do
          {:ok, parsed} -> handle_shorthand(parsed, user, chat_id, context)
          :error -> answer(context, "輸入 /help 查看說明。")
        end

      "add_amount" ->
        case LedgerBot.Schema.Transaction.amount_from_string(String.trim(text)) do
          {:ok, minor} ->
            data = session.data |> Map.put(:amount, minor)
            FSM.put(user_id, chat_id, "add_place", data)
            answer(context, "🏪 地點/商家：", reply_markup: Keyboard.cancel_button())
          :error ->
            answer(context, "請輸入有效金額（例：89 或 89.50）")
        end

      "add_place" ->
        data = Map.put(session.data, :place, String.trim(text))
        FSM.put(user_id, chat_id, "add_date", data)
        answer(context, "📅 日期：", reply_markup: Keyboard.date_buttons())

      "add_note" ->
        data = Map.put(session.data, :note, String.trim(text))
        FSM.put(user_id, chat_id, "add_confirm", data)
        answer(context, Formatter.transaction_summary(data), reply_markup: Keyboard.confirm_buttons(), parse_mode: "Markdown")

      "book_name" ->
        name = String.trim(text)
        if byte_size(name) > 0 and byte_size(name) <= 100 do
          case Books.create(%{name: name, currency: "TWD"}, user.id) do
            {:ok, book} ->
              FSM.set_book(user_id, chat_id, book.id)
              FSM.reset(user_id, chat_id)
              answer(context, "✅ 帳本「#{book.name}」已建立！")
            {:error, _} ->
              answer(context, "❌ 建立失敗，請稍後再試。")
          end
        else
          answer(context, "帳本名稱不能空白或超過100字。")
        end

      "edit_value" ->
        handle_edit_value(text, user, chat_id, session, context)

      _ ->
        answer(context, "請依提示操作，或輸入 /help。")
    end
  end

  # Non-text messages (photos, stickers, etc.)
  def handle({:message, _msg}, _context), do: :ok

  # ── Command handlers ───────────────────────────────────────────────────────

  def handle({:command, :start, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    books = Books.list_for_user(user.id)

    if Enum.empty?(books) do
      FSM.put(user_id, chat_id, "book_name", %{})
      answer(context, "👋 歡迎！請輸入第一個帳本的名稱：")
    else
      book = hd(books)
      FSM.set_book(user_id, chat_id, book.id)
      answer(context, "👋 歡迎回來！帳本：*#{book.name}*", parse_mode: "Markdown")
    end
  end

  def handle({:command, :add, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)

    with {:book, book_id} when not is_nil(book_id) <- {:book, FSM.get_book(user_id, chat_id)},
         {:access, true} <- {:access, Books.is_collaborator?(book_id, user.id)} do
      recents = FSM.get_recents(user_id)
      FSM.put(user_id, chat_id, "add_type", %{book_id: book_id})
      kb = Keyboard.type_buttons()

      if Enum.empty?(recents) do
        answer(context, "➕ 新增記帳\n\n類型：", reply_markup: kb)
      else
        quick_kb = Keyboard.recent_entries_row(recents)
        answer(context, "⚡️ 快速重複：", reply_markup: quick_kb)
        answer(context, "➕ 類型：", reply_markup: kb)
      end
    else
      {:book, nil} -> answer(context, "請先使用 /start 建立帳本。")
      {:access, false} -> answer(context, "您沒有此帳本的存取權限。")
    end
  end

  def handle({:command, :list, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    book_id = FSM.get_book(user_id, chat_id)

    if book_id && Books.is_collaborator?(book_id, user.id) do
      txns = Ledger.list_recent(book_id, limit: 10)
      total = Ledger.count_active(book_id)

      if Enum.empty?(txns) do
        answer(context, "沒有記錄。")
      else
        lines = txns |> Enum.with_index(1) |> Enum.map(fn {t, i} -> Formatter.transaction_row(t, i) end)
        answer(context, "📋 *最近（共#{total}筆）*\n\n" <> Enum.join(lines, "\n"), parse_mode: "Markdown")
      end
    else
      answer(context, "請先使用 /start 建立帳本。")
    end
  end

  def handle({:command, :month, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    book_id = FSM.get_book(user_id, chat_id)

    if book_id && Books.is_collaborator?(book_id, user.id) do
      today = Date.utc_today()
      summary = Ledger.monthly_summary(book_id, today.year, today.month)
      answer(context, Formatter.monthly_summary_text(summary, today.year, today.month), parse_mode: "Markdown")
    else
      answer(context, "請先使用 /start 建立帳本。")
    end
  end

  def handle({:command, :year, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    book_id = FSM.get_book(user_id, chat_id)

    if book_id && Books.is_collaborator?(book_id, user.id) do
      year = Date.utc_today().year
      rows = Ledger.annual_summary(book_id, year)
      answer(context, Formatter.annual_summary_text(rows, year), parse_mode: "Markdown")
    else
      answer(context, "請先使用 /start 建立帳本。")
    end
  end

  def handle({:command, :books, msg}, context) do
    user_id = msg.from.id
    {:ok, user} = Users.get_or_create(user_id)
    books = Books.list_for_user(user.id)

    if Enum.empty?(books) do
      answer(context, "您還沒有帳本。使用 /start 建立。")
    else
      lines = Enum.map(books, fn b -> "• #{b.name} (ID: #{b.id})" end)
      answer(context, "📚 *您的帳本：*\n\n" <> Enum.join(lines, "\n"), parse_mode: "Markdown")
    end
  end

  def handle({:command, :invite, msg}, context) do
    user_id = msg.from.id
    {:ok, _user} = Users.get_or_create(user_id)
    parts = String.split(msg.text || "", ~r/\s+/, trim: true)

    case parts do
      [_, "@" <> _ | _] -> answer(context, "📨 邀請功能需在群組中操作，請先將 Bot 加入群組。")
      _ -> answer(context, "用法：/invite @username 帳本名稱")
    end
  end

  def handle({:command, :delete, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    book_id = FSM.get_book(user_id, chat_id)

    if book_id && Books.is_collaborator?(book_id, user.id) do
      txns = Ledger.list_recent(book_id, limit: 10)

      if Enum.empty?(txns) do
        answer(context, "沒有可刪除的記錄。")
      else
        rows =
          txns
          |> Enum.with_index(1)
          |> Enum.map(fn {t, i} ->
            label = "#{i}. #{t.date} #{t.place} #{Formatter.amount(t.amount)}"
            [%ExGram.Model.InlineKeyboardButton{text: label, callback_data: "delete:#{t.id}"}]
          end)

        kb = ExGram.Dsl.create_inline_keyboard(rows ++ [[%ExGram.Model.InlineKeyboardButton{text: "❌ 取消", callback_data: "cancel"}]])
        FSM.put(user_id, chat_id, "delete_pick", %{book_id: book_id})
        answer(context, "🗑️ 選擇要刪除：", reply_markup: kb)
      end
    else
      answer(context, "請先使用 /start 建立帳本。")
    end
  end

  def handle({:command, :edit, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    book_id = FSM.get_book(user_id, chat_id)

    if book_id && Books.is_collaborator?(book_id, user.id) do
      txns = Ledger.list_recent(book_id, limit: 10)

      if Enum.empty?(txns) do
        answer(context, "沒有可編輯的記錄。")
      else
        rows =
          txns
          |> Enum.with_index(1)
          |> Enum.map(fn {t, i} ->
            label = "#{i}. #{t.date} #{t.place} #{Formatter.amount(t.amount)}"
            [%ExGram.Model.InlineKeyboardButton{text: label, callback_data: "edit_pick:#{t.id}"}]
          end)

        kb = ExGram.Dsl.create_inline_keyboard(rows ++ [[%ExGram.Model.InlineKeyboardButton{text: "❌ 取消", callback_data: "cancel"}]])
        FSM.put(user_id, chat_id, "edit_pick", %{book_id: book_id})
        answer(context, "✏️ 選擇要編輯：", reply_markup: kb)
      end
    else
      answer(context, "請先使用 /start 建立帳本。")
    end
  end

  def handle({:command, :categories, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    book_id = FSM.get_book(user_id, chat_id)

    if book_id && Books.is_collaborator?(book_id, user.id) do
      cats = Categories.list_parents(book_id)
      lines = Enum.map(cats, fn c ->
        icon = if c.icon, do: "#{c.icon} ", else: ""
        "• #{icon}#{c.name} (#{c.type})"
      end)
      answer(context, "🏷️ *分類：*\n\n" <> Enum.join(lines, "\n"), parse_mode: "Markdown")
    else
      answer(context, "請先使用 /start 建立帳本。")
    end
  end

  def handle({:command, :help, _msg}, context) do
    answer(context, """
    📖 *LedgerBot*

    *快速記帳：*
    `飲食 麥當勞 89`
    `薪水 公司 50000`
    `20260115 早餐 麥當勞 89`

    /add /list /edit /delete
    /month /year /books /categories
    """, parse_mode: "Markdown")
  end

  # ── Callback query handler ─────────────────────────────────────────────────

  def handle({:callback_query, %{data: data, from: from, message: msg} = callback_query}, context) do
    user_id = from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    session = FSM.get(user_id, chat_id)

    context
    |> handle_callback(data, user, user_id, chat_id, msg, session)
    |> answer_callback(callback_query)
  end

  # ── Callback dispatch ──────────────────────────────────────────────────────

  defp handle_callback(context, "cancel", _user, user_id, chat_id, msg, _session) do
    FSM.reset(user_id, chat_id)
    edit(context, :inline, msg, "已取消。", [])
  end

  defp handle_callback(context, "noop", _user, _user_id, _chat_id, _msg, _session), do: context

  defp handle_callback(context, "type:" <> type, _user, user_id, chat_id, msg, session)
       when type in ["expense", "income"] and session.fsm_state == "add_type" do
    book_id = session.data[:book_id] || FSM.get_book(user_id, chat_id)
    cats = Categories.list_parents(book_id, type)
    type_label = if type == "expense", do: "💸 支出", else: "💰 收入"
    FSM.put(user_id, chat_id, "add_category", %{type: type, book_id: book_id})
    edit(context, :inline, msg, "#{type_label} → 分類：", reply_markup: Keyboard.category_grid_paged(cats, 1))
  end

  defp handle_callback(context, "cat_page:" <> page_str, _user, user_id, chat_id, msg, session)
       when session.fsm_state == "add_category" do
    page = String.to_integer(page_str)
    book_id = session.data[:book_id]
    type = session.data[:type]
    cats = Categories.list_parents(book_id, type)
    type_label = if type == "expense", do: "💸 支出", else: "💰 收入"
    FSM.put(user_id, chat_id, "add_category", session.data)
    edit(context, :inline, msg, "#{type_label} → 分類：", reply_markup: Keyboard.category_grid_paged(cats, page))
  end

  defp handle_callback(context, "cat:" <> cat_id_str, _user, user_id, chat_id, msg, session)
       when session.fsm_state == "add_category" do
    cat_id = String.to_integer(cat_id_str)
    cat = Categories.get(cat_id)
    subcats = Categories.list_subcategories(cat_id)
    data_map = Map.merge(session.data, %{category_id: cat_id, category_name: cat.name})
    type_label = if session.data[:type] == "expense", do: "💸 支出", else: "💰 收入"
    cat_icon = if cat.icon, do: "#{cat.icon} ", else: ""

    if Enum.empty?(subcats) do
      FSM.put(user_id, chat_id, "add_amount", data_map)
      edit(context, :inline, msg,
        "#{type_label} → #{cat_icon}#{cat.name}\n\n💰 請輸入金額：", [])
    else
      FSM.put(user_id, chat_id, "add_subcategory", data_map)
      edit(context, :inline, msg,
        "#{type_label} → #{cat_icon}#{cat.name} → 子分類：",
        reply_markup: Keyboard.subcategory_grid(subcats, cat_id))
    end
  end

  defp handle_callback(context, "subcat:skip", _user, user_id, chat_id, msg, session)
       when session.fsm_state == "add_subcategory" do
    FSM.put(user_id, chat_id, "add_amount", session.data)
    type_label = if session.data[:type] == "expense", do: "💸 支出", else: "💰 收入"
    cat_name = session.data[:category_name]
    edit(context, :inline, msg,
      "#{type_label} → #{cat_name}\n\n💰 請輸入金額：", [])
  end

  defp handle_callback(context, "subcat:" <> subcat_id_str, _user, user_id, chat_id, msg, session)
       when session.fsm_state == "add_subcategory" do
    subcat_id = String.to_integer(subcat_id_str)
    subcat = Categories.get(subcat_id)
    data_map = Map.merge(session.data, %{subcategory_id: subcat_id, subcategory_name: subcat.name})
    FSM.put(user_id, chat_id, "add_amount", data_map)
    type_label = if session.data[:type] == "expense", do: "💸 支出", else: "💰 收入"
    cat_name = session.data[:category_name]
    edit(context, :inline, msg,
      "#{type_label} → #{cat_name} → #{subcat.name}\n\n💰 請輸入金額：", [])
  end

  defp handle_callback(context, "date:" <> date_str, _user, user_id, chat_id, msg, session)
       when session.fsm_state == "add_date" do
    {:ok, date} = Date.from_iso8601(date_str)
    data_map = Map.put(session.data, :date, Date.to_iso8601(date))
    FSM.put(user_id, chat_id, "add_confirm", data_map)
    edit(context, :inline, msg, Formatter.transaction_summary(data_map),
      parse_mode: "Markdown", reply_markup: Keyboard.confirm_buttons())
  end

  defp handle_callback(context, "confirm:yes", user, user_id, chat_id, msg, session)
       when session.fsm_state == "add_confirm" do
    data_map = session.data
    today = Date.utc_today() |> Date.to_iso8601()

    attrs = %{
      account_book_id: data_map[:book_id],
      user_id: user.id,
      category_id: data_map[:category_id],
      subcategory_id: data_map[:subcategory_id],
      type: data_map[:type],
      amount: data_map[:amount],
      place: data_map[:place],
      note: data_map[:note],
      date: data_map[:date] || today
    }

    case Ledger.add(attrs) do
      {:ok, _txn} ->
        FSM.push_recent(user_id, %{category_name: data_map[:category_name], place: data_map[:place]})
        FSM.reset(user_id, chat_id)
        edit(context, :inline, msg,
          "✅ 已記帳！#{Formatter.amount(data_map[:amount])} @ #{data_map[:place]}", [])
      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {m, _} -> m end)
        edit(context, :inline, msg, "❌ 失敗：#{inspect(errors)}", [])
    end
  end

  defp handle_callback(context, "delete:" <> txn_id_str, _user, user_id, chat_id, msg, session)
       when session.fsm_state == "delete_pick" do
    txn_id = String.to_integer(txn_id_str)
    book_id = session.data[:book_id]

    case Ledger.get_for_user(txn_id, book_id) do
      nil ->
        edit(context, :inline, msg, "找不到此記錄。", [])
      txn ->
        Ledger.soft_delete(txn)
        FSM.reset(user_id, chat_id)
        edit(context, :inline, msg, "✅ 已刪除：#{txn.place} #{Formatter.amount(txn.amount)}", [])
    end
  end

  defp handle_callback(context, "edit_pick:" <> txn_id_str, _user, user_id, chat_id, msg, session)
       when session.fsm_state == "edit_pick" do
    txn_id = String.to_integer(txn_id_str)
    data_map = Map.put(session.data, :txn_id, txn_id)
    FSM.put(user_id, chat_id, "edit_field", data_map)
    kb = ExGram.Dsl.create_inline_keyboard([
      [%ExGram.Model.InlineKeyboardButton{text: "💰 金額", callback_data: "edit_field:amount"},
       %ExGram.Model.InlineKeyboardButton{text: "🏪 地點", callback_data: "edit_field:place"}],
      [%ExGram.Model.InlineKeyboardButton{text: "📅 日期", callback_data: "edit_field:date"},
       %ExGram.Model.InlineKeyboardButton{text: "❌ 取消", callback_data: "cancel"}]
    ])
    edit(context, :inline, msg, "✏️ 修改欄位：", reply_markup: kb)
  end

  defp handle_callback(context, "edit_field:" <> field, _user, user_id, chat_id, msg, session) do
    data_map = Map.put(session.data, :edit_field, field)
    FSM.put(user_id, chat_id, "edit_value", data_map)
    prompt = case field do
      "amount" -> "輸入新金額："
      "place"  -> "輸入新地點："
      "date"   -> "輸入新日期 (YYYY-MM-DD)："
      _        -> "輸入新值："
    end
    edit(context, :inline, msg, "✏️ #{prompt}", [])
  end

  defp handle_callback(context, "quick:" <> cat_and_place, _user, user_id, chat_id, msg, _session) do
    [cat_name, place] = String.split(cat_and_place, ":", parts: 2)
    book_id = FSM.get_book(user_id, chat_id)
    cat = Categories.find_by_name(book_id, cat_name)

    if cat do
      data_map = %{
        book_id: book_id,
        type: cat.type,
        category_id: cat.id,
        category_name: cat.name,
        place: place
      }
      FSM.put(user_id, chat_id, "add_amount", data_map)
      edit(context, :inline, msg, "#{cat.name} → #{place}\n\n💰 請輸入金額：", [])
    else
      edit(context, :inline, msg, "找不到分類，請重新操作。", [])
    end
  end

  defp handle_callback(context, _data, _user, _user_id, _chat_id, _msg, _session), do: context

  # ── Private helpers ────────────────────────────────────────────────────────

  defp handle_shorthand(parsed, user, chat_id, context) do
    user_id = user.telegram_id
    book_id = FSM.get_book(user_id, chat_id)

    if book_id && Books.is_collaborator?(book_id, user.id) do
      cat = Categories.find_by_name(book_id, parsed.category_name)

      if cat do
        data_map = %{
          book_id: book_id,
          type: parsed.type,
          category_id: cat.id,
          category_name: cat.name,
          place: parsed.place,
          amount: parsed.amount,
          date: (parsed.date && Date.to_iso8601(parsed.date)) || Date.to_iso8601(Date.utc_today())
        }
        FSM.put(user_id, chat_id, "add_confirm", data_map)
        answer(context, Formatter.transaction_summary(data_map),
          reply_markup: Keyboard.confirm_buttons(), parse_mode: "Markdown")
      else
        answer(context, "找不到分類「#{parsed.category_name}」")
      end
    else
      answer(context, "請先使用 /start 建立帳本。")
    end
  end

  defp handle_edit_value(text, user, chat_id, session, context) do
    user_id = user.telegram_id
    txn_id = session.data[:txn_id]
    field = session.data[:edit_field]
    book_id = session.data[:book_id]

    case Ledger.get_for_user(txn_id, book_id) do
      nil ->
        FSM.reset(user_id, chat_id)
        answer(context, "找不到記錄。")

      txn ->
        update_attrs = case field do
          "amount" ->
            case LedgerBot.Schema.Transaction.amount_from_string(String.trim(text)) do
              {:ok, minor} -> %{amount: minor}
              :error -> nil
            end
          "place" ->
            place = String.trim(text)
            if byte_size(place) > 0 and byte_size(place) <= 100, do: %{place: place}, else: nil
          "date" ->
            case Date.from_iso8601(String.trim(text)) do
              {:ok, date} -> %{date: Date.to_iso8601(date)}
              _ -> nil
            end
          _ -> nil
        end

        if update_attrs do
          case Ledger.update(txn, update_attrs) do
            {:ok, _} ->
              FSM.reset(user_id, chat_id)
              answer(context, "✅ 已更新！")
            {:error, _} ->
              answer(context, "❌ 更新失敗，請稍後再試。")
          end
        else
          answer(context, "格式不正確，請重新輸入。")
        end
    end
  end
end
