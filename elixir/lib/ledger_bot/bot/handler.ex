defmodule LedgerBot.Bot.Handler do
  @moduledoc "ExGram bot handler: dispatches messages and callbacks to command modules."

  use ExGram.Bot, name: :ledger_bot, setup_commands: true

  alias LedgerBot.Bot.{FSM, Parser, Keyboard, Formatter}
  alias LedgerBot.Context.{Users, Books, Ledger, Categories}

  # ── Commands ──────────────────────────────────────────────────────────────

  command("start",   description: "👋 開始使用")
  command("add",     description: "➕ 新增記帳")
  command("list",    description: "📋 查看記錄")
  command("edit",    description: "✏️ 編輯記錄")
  command("delete",  description: "🗑️ 刪除記錄")
  command("month",   description: "📅 本月統計")
  command("year",    description: "📊 年度統計")
  command("books",   description: "📚 帳本管理")
  command("invite",  description: "🔗 邀請成員")
  command("categories", description: "🏷️ 分類管理")
  command("help",    description: "❓ 說明")

  # ── Message handler (plain text, not a command) ───────────────────────────

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

      "add_place" ->
        data = Map.put(session.data, :place, String.trim(text))
        FSM.put(user_id, chat_id, "add_date", data)
        answer(context, "📅 請選擇日期：", reply_markup: Keyboard.date_buttons())

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

  # Non-text messages (photos, stickers, etc.) — ignore silently
  def handle({:message, _msg}, _context), do: :ok

  # ── Inline command handlers ────────────────────────────────────────────────

  def handle({:command, :start, msg}, context) do
    user_id = msg.from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    books = Books.list_for_user(user.id)

    cond do
      Enum.empty?(books) ->
        FSM.put(user_id, chat_id, "book_name", %{})
        answer(context, "👋 歡迎！請輸入您第一個帳本的名稱：")

      true ->
        book = hd(books)
        FSM.set_book(user_id, chat_id, book.id)
        answer(context, "👋 歡迎回來！目前帳本：*#{book.name}*\n\n輸入 /help 查看所有指令。", parse_mode: "Markdown")
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

      quick_kb = Keyboard.recent_entries_row(recents)
      kb = Keyboard.type_buttons()

      quick_text =
        if quick_kb do
          "\n\n⚡️ *快速重複：*"
        else
          ""
        end

      answer(context, "➕ *新增記帳*#{quick_text}\n\n請選擇類型：",
        reply_markup: kb, parse_mode: "Markdown")
    else
      {:book, nil} ->
        answer(context, "請先使用 /start 建立帳本。")
      {:access, false} ->
        answer(context, "您沒有此帳本的存取權限。")
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
        answer(context, "📋 目前沒有記帳記錄。")
      else
        lines = txns |> Enum.with_index(1) |> Enum.map(fn {t, i} -> Formatter.transaction_row(t, i) end)
        text = "📋 *最近記錄*（共#{total}筆）\n\n" <> Enum.join(lines, "\n")
        answer(context, text, parse_mode: "Markdown")
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
      text = Formatter.monthly_summary_text(summary, today.year, today.month)
      answer(context, text, parse_mode: "Markdown")
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
      text = Formatter.annual_summary_text(rows, year)
      answer(context, text, parse_mode: "Markdown")
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

    with ["@" <> _ | _] <- tl(parts),
         [_, _username | rest] <- parts,
         book_name when book_name != "" <- Enum.join(rest, " ") do
      answer(context, "📨 邀請功能需在群組中操作，請先將 Bot 加入群組。")
    else
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
          |> Enum.chunk_every(1)
          |> Enum.map(fn [{t, i}] ->
            label = "#{i}. #{t.date} #{t.place} #{Formatter.amount(t.amount)}"
            [%ExGram.Model.InlineKeyboardButton{text: label, callback_data: "delete:#{t.id}"}]
          end)

        kb = ExGram.Dsl.create_inline_keyboard(rows ++ [[%ExGram.Model.InlineKeyboardButton{text: "❌ 取消", callback_data: "cancel"}]])
        FSM.put(user_id, chat_id, "delete_pick", %{book_id: book_id})
        answer(context, "🗑️ 選擇要刪除的記錄：", reply_markup: kb)
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
        answer(context, "✏️ 選擇要編輯的記錄：", reply_markup: kb)
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
      answer(context, "🏷️ *分類列表：*\n\n" <> Enum.join(lines, "\n"), parse_mode: "Markdown")
    else
      answer(context, "請先使用 /start 建立帳本。")
    end
  end

  def handle({:command, :help, _msg}, context) do
    answer(context, """
    📖 *LedgerBot 說明*

    *快速記帳（直接輸入）：*
    `飲食 麥當勞 89` — 記支出
    `薪水 公司 50000` — 記收入
    `20260115 早餐 麥當勞 89` — 指定日期

    *指令：*
    /add — 逐步新增記帳
    /list — 查看最近記錄
    /edit — 編輯記錄
    /delete — 刪除記錄
    /month — 本月統計
    /year — 年度統計
    /books — 帳本管理
    /categories — 分類管理
    /help — 此說明
    """, parse_mode: "Markdown")
  end

  # ── Callback query handlers ────────────────────────────────────────────────

  def handle({:callback_query, %{data: data, from: from, message: msg}}, context) do
    user_id = from.id
    chat_id = msg.chat.id
    {:ok, user} = Users.get_or_create(user_id)
    session = FSM.get(user_id, chat_id)

    case String.split(data, ":", parts: 2) do
      ["cancel"] ->
        FSM.reset(user_id, chat_id)
        answer(context, "已取消。")

      ["type", type] when type in ["expense", "income"] and session.fsm_state == "add_type" ->
        book_id = session.data[:book_id] || FSM.get_book(user_id, chat_id)
        data_map = %{type: type, book_id: book_id}
        FSM.put(user_id, chat_id, "add_category", data_map)
        cats = Categories.list_parents(book_id, type)
        answer(context, "📂 請選擇分類：", reply_markup: Keyboard.category_grid(cats))

      ["cat", cat_id_str] when session.fsm_state == "add_category" ->
        cat_id = String.to_integer(cat_id_str)
        cat = Categories.get(cat_id)
        subcats = Categories.list_subcategories(cat_id)
        data_map = Map.merge(session.data, %{category_id: cat_id, category_name: cat.name})
        FSM.put(user_id, chat_id, "add_subcategory", data_map)

        if Enum.empty?(subcats) do
          FSM.put(user_id, chat_id, "add_amount", Map.put(data_map, :amount_str, ""))
          answer(context, "💰 請輸入金額：", reply_markup: Keyboard.numpad(""))
        else
          answer(context, "📂 請選擇子分類：", reply_markup: Keyboard.subcategory_grid(subcats, cat_id))
        end

      ["subcat", "skip"] when session.fsm_state == "add_subcategory" ->
        data_map = Map.put(session.data, :amount_str, "")
        FSM.put(user_id, chat_id, "add_amount", data_map)
        answer(context, "💰 請輸入金額：", reply_markup: Keyboard.numpad(""))

      ["subcat", subcat_id_str] when session.fsm_state == "add_subcategory" ->
        subcat_id = String.to_integer(subcat_id_str)
        subcat = Categories.get(subcat_id)
        data_map = Map.merge(session.data, %{subcategory_id: subcat_id, subcategory_name: subcat.name, amount_str: ""})
        FSM.put(user_id, chat_id, "add_amount", data_map)
        answer(context, "💰 請輸入金額：", reply_markup: Keyboard.numpad(""))

      ["num", digit] when session.fsm_state == "add_amount" ->
        current = session.data[:amount_str] || ""
        new_str = update_amount_str(current, digit)
        data_map = Map.put(session.data, :amount_str, new_str)
        FSM.put(user_id, chat_id, "add_amount", data_map)
        answer(context, "💰 請輸入金額：", reply_markup: Keyboard.numpad(new_str))

      ["num", "confirm"] when session.fsm_state == "add_amount" ->
        amount_str = session.data[:amount_str] || "0"
        case LedgerBot.Schema.Transaction.amount_from_string(amount_str) do
          {:ok, minor} ->
            data_map = Map.merge(session.data, %{amount: minor})
            |> Map.delete(:amount_str)
            FSM.put(user_id, chat_id, "add_place", data_map)
            answer(context, "🏪 請輸入地點/商家：", reply_markup: Keyboard.cancel_button())
          :error ->
            answer(context, "請輸入有效金額。", reply_markup: Keyboard.numpad(amount_str))
        end

      ["date", date_str] when session.fsm_state == "add_date" ->
        {:ok, date} = Date.from_iso8601(date_str)
        data_map = Map.put(session.data, :date, Date.to_iso8601(date))
        FSM.put(user_id, chat_id, "add_confirm", data_map)
        answer(context, Formatter.transaction_summary(data_map), reply_markup: Keyboard.confirm_buttons(), parse_mode: "Markdown")

      ["confirm", "yes"] when session.fsm_state == "add_confirm" ->
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
            answer(context, "✅ 已記帳！#{Formatter.amount(data_map[:amount])} @ #{data_map[:place]}")
          {:error, changeset} ->
            errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
            answer(context, "❌ 記帳失敗：#{inspect(errors)}")
        end

      ["delete", txn_id_str] when session.fsm_state == "delete_pick" ->
        txn_id = String.to_integer(txn_id_str)
        book_id = session.data[:book_id]

        case Ledger.get_for_user(txn_id, book_id) do
          nil -> answer(context, "找不到此記錄。")
          txn ->
            Ledger.soft_delete(txn)
            FSM.reset(user_id, chat_id)
            answer(context, "✅ 已刪除：#{txn.place} #{Formatter.amount(txn.amount)}")
        end

      ["edit_pick", txn_id_str] when session.fsm_state == "edit_pick" ->
        txn_id = String.to_integer(txn_id_str)
        data_map = Map.put(session.data, :txn_id, txn_id)
        FSM.put(user_id, chat_id, "edit_field", data_map)
        kb = ExGram.Dsl.create_inline_keyboard([
          [%ExGram.Model.InlineKeyboardButton{text: "💰 金額", callback_data: "edit_field:amount"}],
          [%ExGram.Model.InlineKeyboardButton{text: "📂 分類", callback_data: "edit_field:category"}],
          [%ExGram.Model.InlineKeyboardButton{text: "🏪 地點", callback_data: "edit_field:place"}],
          [%ExGram.Model.InlineKeyboardButton{text: "📅 日期", callback_data: "edit_field:date"}],
          [%ExGram.Model.InlineKeyboardButton{text: "❌ 取消", callback_data: "cancel"}]
        ])
        answer(context, "✏️ 選擇要修改的欄位：", reply_markup: kb)

      ["edit_field", field] ->
        data_map = Map.put(session.data, :edit_field, field)
        FSM.put(user_id, chat_id, "edit_value", data_map)
        prompt = case field do
          "amount"   -> "請輸入新金額："
          "place"    -> "請輸入新地點："
          "date"     -> "請輸入新日期 (YYYY-MM-DD)："
          "category" -> "請輸入新分類名稱："
          _ -> "請輸入新值："
        end
        answer(context, prompt, reply_markup: Keyboard.cancel_button())

      ["quick", cat_and_place] ->
        [cat_name, place] = String.split(cat_and_place, ":", parts: 2)
        book_id = FSM.get_book(user_id, chat_id)
        cat = Categories.find_by_name(book_id, cat_name)

        if cat do
          data_map = %{
            book_id: book_id,
            type: cat.type,
            category_id: cat.id,
            category_name: cat.name,
            place: place,
            amount_str: ""
          }
          FSM.put(user_id, chat_id, "add_amount", data_map)
          answer(context, "💰 請輸入金額：", reply_markup: Keyboard.numpad(""))
        else
          answer(context, "找不到分類，請重新操作。")
        end

      _ ->
        :ok
    end
  end

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
        answer(context, Formatter.transaction_summary(data_map), reply_markup: Keyboard.confirm_buttons(), parse_mode: "Markdown")
      else
        answer(context, "找不到分類「#{parsed.category_name}」，請先用 /add 選擇分類。")
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
        update_attrs =
          case field do
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

            _ ->
              nil
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
          answer(context, "輸入格式不正確，請重新輸入。")
        end
    end
  end

  defp update_amount_str(current, "back") when byte_size(current) > 0 do
    String.slice(current, 0, byte_size(current) - 1)
  end

  defp update_amount_str(current, "back"), do: current

  defp update_amount_str(current, ".") do
    if String.contains?(current, "."), do: current, else: current <> "."
  end

  defp update_amount_str(current, digit) when byte_size(current) < 10 do
    current <> digit
  end

  defp update_amount_str(current, _digit), do: current
end
