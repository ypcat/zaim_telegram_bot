#!/usr/bin/env elixir

# Account Bot 2.0 — Telegram bookkeeping bot backed by Google Sheets
# See spec_v2.md for full specification.
#
# Usage:
#   elixir account_bot.exs
#   elixir account_bot.exs --import FILE --sheet-id ID --chat-id ID [--dry-run] [--user NAME]

Mix.install([
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

# ===========================================================================
# Config — loads config.json
# ===========================================================================
defmodule AB.Config do
  def load do
    path = Path.join(File.cwd!(), "config.json")

    case File.read(path) do
      {:ok, data} -> Jason.decode!(data)
      {:error, _} -> raise "Cannot read #{path}. See spec_v2.md §11 for setup."
    end
  end
end

# ===========================================================================
# State — Agent wrapping state.json persistence
# ===========================================================================
defmodule AB.State do
  use Agent

  @state_file "state.json"

  def start_link do
    Agent.start_link(fn -> load_disk() end, name: __MODULE__)
  end

  def get_user(chat_id) do
    Agent.get(__MODULE__, &get_in(&1, ["users", to_string(chat_id)]))
  end

  def put_user(chat_id, data) do
    Agent.update(__MODULE__, fn st ->
      put_in(st, ["users", to_string(chat_id)], data) |> save_disk()
    end)
  end

  def get_group(gid) do
    Agent.get(__MODULE__, &get_in(&1, ["groups", to_string(gid)]))
  end

  def put_group(gid, data) do
    Agent.update(__MODULE__, fn st ->
      put_in(st, ["groups", to_string(gid)], data) |> save_disk()
    end)
  end

  # Resolve tokens — follows owner_chat_id for collaborators
  def get_tokens(chat_id) do
    case get_user(chat_id) do
      %{"role" => "owner", "google_tokens" => t} -> t
      %{"role" => "collaborator", "owner_chat_id" => oid} ->
        case get_user(oid) do
          %{"google_tokens" => t} -> t
          _ -> nil
        end
      _ -> nil
    end
  end

  def get_sheet_id(chat_id) do
    case get_user(chat_id) do
      %{"spreadsheet_id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  def update_tokens(chat_id, tokens) do
    Agent.update(__MODULE__, fn st ->
      put_in(st, ["users", to_string(chat_id), "google_tokens"], tokens) |> save_disk()
    end)
  end

  # For --import: load from a specific file without starting Agent
  def load_file(path) do
    case File.read(path) do
      {:ok, data} -> Jason.decode!(data)
      {:error, _} -> %{"users" => %{}, "groups" => %{}}
    end
  end

  defp load_disk do
    path = Path.join(File.cwd!(), @state_file)

    case File.read(path) do
      {:ok, data} -> Jason.decode!(data)
      {:error, _} -> %{"users" => %{}, "groups" => %{}}
    end
  end

  defp save_disk(st) do
    path = Path.join(File.cwd!(), @state_file)
    File.write!(path, Jason.encode!(st, pretty: true))
    st
  end
end

# ===========================================================================
# Google — OAuth + Sheets + Drive API
# ===========================================================================
defmodule AB.Google do
  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @sheets "https://sheets.googleapis.com/v4/spreadsheets"
  @drive "https://www.googleapis.com/drive/v3/files"
  @scopes "https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/drive.file"
  @redirect "http://localhost"

  # --- OAuth ---

  def auth_url(config) do
    params =
      URI.encode_query(%{
        client_id: config["google_client_id"],
        redirect_uri: @redirect,
        response_type: "code",
        scope: @scopes,
        access_type: "offline",
        prompt: "consent"
      })

    "#{@auth_url}?#{params}"
  end

  def exchange_code(config, code) do
    resp =
      Req.post!(@token_url,
        form: [
          code: String.trim(code),
          client_id: config["google_client_id"],
          client_secret: config["google_client_secret"],
          redirect_uri: @redirect,
          grant_type: "authorization_code"
        ]
      )

    case resp.status do
      200 ->
        b = resp.body

        {:ok,
         %{
           "access_token" => b["access_token"],
           "refresh_token" => b["refresh_token"],
           "expires_at" => expires_at(b["expires_in"])
         }}

      _ ->
        {:error, resp.body}
    end
  end

  def refresh(config, refresh_token) do
    resp =
      Req.post!(@token_url,
        form: [
          refresh_token: refresh_token,
          client_id: config["google_client_id"],
          client_secret: config["google_client_secret"],
          grant_type: "refresh_token"
        ]
      )

    case resp.status do
      200 ->
        b = resp.body

        {:ok,
         %{
           "access_token" => b["access_token"],
           "refresh_token" => refresh_token,
           "expires_at" => expires_at(b["expires_in"])
         }}

      _ ->
        {:error, resp.body}
    end
  end

  # Get valid access_token, auto-refreshing if expired.
  # Returns {:ok, token} or {:error, reason}
  def access_token(config, chat_id) do
    tokens = AB.State.get_tokens(chat_id)

    cond do
      is_nil(tokens) ->
        {:error, :no_tokens}

      token_expired?(tokens) ->
        case refresh(config, tokens["refresh_token"]) do
          {:ok, new} ->
            owner_id =
              case AB.State.get_user(chat_id) do
                %{"role" => "collaborator", "owner_chat_id" => oid} -> oid
                _ -> chat_id
              end

            AB.State.update_tokens(owner_id, new)
            {:ok, new["access_token"]}

          err ->
            err
        end

      true ->
        {:ok, tokens["access_token"]}
    end
  end

  # Convenience: get token from raw token map (for --import without Agent)
  def access_token_raw(config, tokens) do
    if token_expired?(tokens) do
      refresh(config, tokens["refresh_token"])
    else
      {:ok, tokens}
    end
  end

  # --- Drive ---

  def find_spreadsheet(at, name) do
    q = "name='#{name}' and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false"

    resp =
      Req.get!(@drive,
        headers: [{"authorization", "Bearer #{at}"}],
        params: [q: q, fields: "files(id,name)"]
      )

    case resp.status do
      200 -> {:ok, resp.body["files"]}
      _ -> {:error, resp.body}
    end
  end

  # --- Sheets ---

  def create_spreadsheet(at, title, tab_names) do
    body = %{
      properties: %{title: title},
      sheets: Enum.map(tab_names, &%{properties: %{title: &1}})
    }

    resp = Req.post!(@sheets, headers: [{"authorization", "Bearer #{at}"}], json: body)

    case resp.status do
      200 -> {:ok, resp.body}
      _ -> {:error, resp.body}
    end
  end

  def read_values(at, sid, range) do
    url = "#{@sheets}/#{sid}/values/#{URI.encode(range)}"
    resp = Req.get!(url, headers: [{"authorization", "Bearer #{at}"}])

    case resp.status do
      200 -> {:ok, resp.body["values"] || []}
      _ -> {:error, resp.body}
    end
  end

  def append_values(at, sid, range, rows) do
    url = "#{@sheets}/#{sid}/values/#{URI.encode(range)}:append"

    resp =
      Req.post!(url,
        headers: [{"authorization", "Bearer #{at}"}],
        params: [valueInputOption: "USER_ENTERED", insertDataOption: "INSERT_ROWS"],
        json: %{values: rows}
      )

    case resp.status do
      200 -> {:ok, resp.body}
      _ -> {:error, resp.body}
    end
  end

  def update_values(at, sid, range, rows) do
    url = "#{@sheets}/#{sid}/values/#{URI.encode(range)}"

    resp =
      Req.put!(url,
        headers: [{"authorization", "Bearer #{at}"}],
        params: [valueInputOption: "USER_ENTERED"],
        json: %{values: rows}
      )

    case resp.status do
      200 -> {:ok, resp.body}
      _ -> {:error, resp.body}
    end
  end

  def get_sheet_meta(at, sid) do
    url = "#{@sheets}/#{sid}"
    resp = Req.get!(url, headers: [{"authorization", "Bearer #{at}"}], params: [fields: "sheets.properties"])

    case resp.status do
      200 -> {:ok, resp.body}
      _ -> {:error, resp.body}
    end
  end

  def delete_row(at, sid, sheet_gid, row_index) do
    url = "#{@sheets}/#{sid}:batchUpdate"

    body = %{
      requests: [
        %{
          deleteDimension: %{
            range: %{sheetId: sheet_gid, dimension: "ROWS", startIndex: row_index, endIndex: row_index + 1}
          }
        }
      ]
    }

    resp = Req.post!(url, headers: [{"authorization", "Bearer #{at}"}], json: body)

    case resp.status do
      200 -> {:ok, resp.body}
      _ -> {:error, resp.body}
    end
  end

  # --- helpers ---

  defp token_expired?(%{"expires_at" => ea}) do
    case DateTime.from_iso8601(ea) do
      {:ok, dt, _} -> DateTime.compare(DateTime.utc_now(), dt) != :lt
      _ -> true
    end
  end

  defp token_expired?(_), do: true

  defp expires_at(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds - 60, :second)
    |> DateTime.to_iso8601()
  end
end

# ===========================================================================
# Telegram — Bot API wrapper
# ===========================================================================
defmodule AB.Telegram do
  @base "https://api.telegram.org/bot"

  def get_updates(token, offset, timeout \\ 30) do
    url = "#{@base}#{token}/getUpdates"

    case Req.get(url,
           params: [offset: offset, timeout: timeout, allowed_updates: Jason.encode!(["message", "callback_query"])],
           receive_timeout: (timeout + 10) * 1000
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => ups}}} ->
        ups

      {:ok, %{status: 409}} ->
        IO.puts("[WARN] Conflict: another bot instance may be running")
        Process.sleep(5000)
        []

      other ->
        IO.puts("[WARN] getUpdates error: #{inspect(other)}")
        Process.sleep(3000)
        []
    end
  end

  def send_msg(token, chat_id, text, opts \\ []) do
    body =
      %{chat_id: chat_id, text: text, parse_mode: "HTML"}
      |> maybe_put(:reply_markup, opts[:reply_markup])

    Req.post!("#{@base}#{token}/sendMessage", json: body)
  end

  def edit_msg(token, chat_id, msg_id, text, opts \\ []) do
    body =
      %{chat_id: chat_id, message_id: msg_id, text: text, parse_mode: "HTML"}
      |> maybe_put(:reply_markup, opts[:reply_markup])

    Req.post!("#{@base}#{token}/editMessageText", json: body)
  end

  def answer_cb(token, cb_id, opts \\ []) do
    body = %{callback_query_id: cb_id} |> maybe_put(:text, opts[:text])
    Req.post!("#{@base}#{token}/answerCallbackQuery", json: body)
  end

  def get_me(token) do
    case Req.get!("#{@base}#{token}/getMe") do
      %{status: 200, body: %{"ok" => true, "result" => me}} -> {:ok, me}
      other -> {:error, other}
    end
  end

  def set_my_commands(token) do
    url = "#{@base}#{token}/setMyCommands"

    commands = [
      %{command: "start", description: "Connect Google account / 連結 Google 帳號"},
      %{command: "input", description: "Record transaction / 記帳 (e.g. 午餐 150)"},
      %{command: "list", description: "View transactions / 歷程明細"},
      %{command: "edit", description: "Edit transaction / 編輯交易"},
      %{command: "delete", description: "Delete transaction / 刪除交易"},
      %{command: "invite", description: "Invite to share account / 邀請協作者"},
      %{command: "help", description: "Show help / 說明"}
    ]

    case Req.post!(url, json: %{commands: commands}) do
      %{status: 200, body: %{"ok" => true}} ->
        IO.puts("✅ Registered Telegram commands successfully")
        {:ok, true}

      other ->
        IO.puts("[WARN] Failed to register Telegram commands: #{inspect(other)}")
        {:error, other}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end

# ===========================================================================
# Categories — seed data + Zaim ID mapping
# ===========================================================================
defmodule AB.Categories do
  @parents %{
    101 => "食費",
    102 => "日用雜貨",
    103 => "交通",
    104 => "通訊",
    105 => "水道光熱",
    106 => "住宅",
    107 => "交際費",
    108 => "娛樂",
    109 => "教育",
    110 => "醫療保健",
    111 => "美容衣服",
    112 => "汽車",
    113 => "稅金",
    114 => "大型出費",
    199 => "其他"
  }

  @subs %{
    10101 => {"食費", "食物"},
    10102 => {"食費", "點心/咖啡"},
    10103 => {"食費", "早餐"},
    10104 => {"食費", "午餐"},
    10105 => {"食費", "晚餐"},
    10199 => {"食費", "其他食費"},
    10201 => {"日用雜貨", "雜貨"},
    10299 => {"日用雜貨", "其他日用"},
    10301 => {"交通", "電車"},
    10302 => {"交通", "計程車"},
    10303 => {"交通", "公車"},
    10304 => {"交通", "機票"},
    10399 => {"交通", "其他交通"},
    10401 => {"通訊", "行動通訊"},
    10402 => {"通訊", "市話"},
    10403 => {"通訊", "網路"},
    10404 => {"通訊", "電視"},
    10405 => {"通訊", "快遞"},
    10406 => {"通訊", "郵票"},
    10499 => {"通訊", "其他通訊"},
    10501 => {"水道光熱", "水費"},
    10502 => {"水道光熱", "電費"},
    10503 => {"水道光熱", "瓦斯"},
    10601 => {"住宅", "房租"},
    10602 => {"住宅", "房貸"},
    10603 => {"住宅", "家具"},
    10604 => {"住宅", "家電"},
    10605 => {"住宅", "裝潢"},
    10701 => {"交際費", "請客"},
    10702 => {"交際費", "禮物"},
    10703 => {"交際費", "紅包"},
    10801 => {"娛樂", "休閒"},
    10802 => {"娛樂", "展覽"},
    10803 => {"娛樂", "電影"},
    10804 => {"娛樂", "音樂"},
    10805 => {"娛樂", "漫畫"},
    10806 => {"娛樂", "書籍"},
    10807 => {"娛樂", "遊戲"},
    10901 => {"教育", "上課"},
    10904 => {"教育", "考試"},
    10905 => {"教育", "學費"},
    11001 => {"醫療保健", "看病"},
    11002 => {"醫療保健", "藥物"},
    11003 => {"醫療保健", "保險"},
    11099 => {"醫療保健", "其他醫療"},
    11101 => {"美容衣服", "衣服"},
    11102 => {"美容衣服", "配件"},
    11104 => {"美容衣服", "健身"},
    11105 => {"美容衣服", "理髮"},
    11106 => {"美容衣服", "化妝品"},
    11107 => {"美容衣服", "美容"},
    11108 => {"美容衣服", "洗衣"},
    11201 => {"汽車", "加油"},
    11202 => {"汽車", "停車"},
    11207 => {"汽車", "過路費"},
    11299 => {"汽車", "其他汽車"},
    11302 => {"稅金", "所得稅"},
    11401 => {"大型出費", "旅行"},
    11402 => {"大型出費", "房屋"},
    11403 => {"大型出費", "汽車購置"},
    11404 => {"大型出費", "機車"},
    11407 => {"大型出費", "看護"},
    11409 => {"大型出費", "其他大型"},
    11499 => {"大型出費", "其他大型"},
    19901 => {"其他", "匯款"},
    19902 => {"其他", "零用"},
    19904 => {"其他", "預付"},
    19905 => {"其他", "立替"},
    19906 => {"其他", "提款"},
    19908 => {"其他", "儲值"},
    19909 => {"其他", "其他"},
    19999 => {"其他", "其他"}
  }

  @income %{11 => "薪水", 12 => "預付返還", 13 => "獎金", 15 => "營收", 19 => "其他收入"}

  @aliases %{
    "買菜" => "食物",
    "下午茶" => "點心/咖啡",
    "咖啡" => "點心/咖啡",
    "雜物" => "雜貨",
    "手機" => "行動通訊",
    "電話" => "市話",
    "電器" => "家電",
    "書" => "書籍",
    "藥" => "藥物",
    "剪髮" => "理髮",
    "掛號" => "看病",
    "轉帳" => "匯款",
    "代買" => "預付",
    "代購" => "預付",
    "收錢" => "其他收入",
    "收款" => "其他收入"
  }

  def parents, do: @parents
  def subs, do: @subs
  def income, do: @income
  def aliases, do: @aliases

  # Resolve Zaim record → {category, subcategory}
  def resolve_zaim("income", cat_id, _genre_id) do
    {Map.get(@income, cat_id, "其他收入"), ""}
  end

  def resolve_zaim("payment", cat_id, genre_id) do
    case Map.get(@subs, genre_id) do
      {cat, sub} -> {cat, sub}
      nil -> {Map.get(@parents, cat_id, "其他"), ""}
    end
  end

  # Build seed rows for the category tab: [[id, parent_id, alias_id, name], ...]
  def seed_rows do
    # 1. Parent expense categories
    sorted_parents = @parents |> Enum.sort_by(&elem(&1, 0))
    {parent_rows, parent_name_to_id} =
      sorted_parents
      |> Enum.with_index(1)
      |> Enum.reduce({[], %{}}, fn {{_zid, name}, idx}, {rows, map} ->
        {[[idx, "", "", name] | rows], Map.put(map, name, idx)}
      end)

    parent_rows = Enum.reverse(parent_rows)
    next = map_size(parent_name_to_id) + 1

    # 2. Subcategories (deduplicated)
    unique_subs =
      @subs
      |> Map.values()
      |> Enum.uniq()
      |> Enum.sort()

    {sub_rows, name_to_id, next} =
      Enum.reduce(unique_subs, {[], parent_name_to_id, next}, fn {par, sub}, {rows, nmap, id} ->
        pid = nmap[par]
        {[[id, pid || "", "", sub] | rows], Map.put(nmap, sub, id), id + 1}
      end)

    sub_rows = Enum.reverse(sub_rows)

    # 3. Income categories (skip if name already exists)
    {inc_rows, name_to_id, next} =
      @income
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({[], name_to_id, next}, fn {_zid, name}, {rows, nmap, id} ->
        if Map.has_key?(nmap, name) do
          {rows, nmap, id}
        else
          {[[id, "", "", name] | rows], Map.put(nmap, name, id), id + 1}
        end
      end)

    inc_rows = Enum.reverse(inc_rows)

    # 4. Aliases
    {alias_rows, _next} =
      @aliases
      |> Enum.sort()
      |> Enum.reduce({[], next}, fn {aname, target}, {rows, id} ->
        tid = name_to_id[target]

        if tid do
          {[[id, "", tid, aname] | rows], id + 1}
        else
          {rows, id}
        end
      end)

    alias_rows = Enum.reverse(alias_rows)

    parent_rows ++ sub_rows ++ inc_rows ++ alias_rows
  end
end

# ===========================================================================
# Conv — per-chat conversation state (Agent)
# ===========================================================================
defmodule AB.Conv do
  use Agent

  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def get(chat_id) do
    Agent.get(__MODULE__, &Map.get(&1, chat_id, %{state: :idle}))
  end

  def put(chat_id, conv) do
    conv = Map.put(conv, :updated_at, System.monotonic_time(:second))
    Agent.update(__MODULE__, &Map.put(&1, chat_id, conv))
  end

  def reset(chat_id) do
    Agent.update(__MODULE__, &Map.delete(&1, chat_id))
  end

  # Cleanup stale conversations (>5 min)
  def cleanup do
    now = System.monotonic_time(:second)

    Agent.update(__MODULE__, fn convs ->
      convs
      |> Enum.reject(fn {_k, v} -> now - (v[:updated_at] || 0) > 300 end)
      |> Map.new()
    end)
  end
end

# ===========================================================================
# Sheets — higher-level sheet operations
# ===========================================================================
defmodule AB.Sheets do
  @tabs ["ledger", "user", "category", "object"]
  @ledger_headers ["date", "user", "income/expense", "category", "subcategory", "amount", "currency", "object", "note"]
  @user_headers ["chat_id", "name", "default_currency"]
  @cat_headers ["id", "parent_id", "alias_id", "name"]
  @obj_headers ["id", "alias_id", "name"]

  def tab_names, do: @tabs
  def ledger_headers, do: @ledger_headers

  # Create a new account spreadsheet with all tabs, headers, and seed data
  def create_account(at, title) do
    with {:ok, ss} <- AB.Google.create_spreadsheet(at, title, @tabs),
         sid = ss["spreadsheetId"],
         {:ok, _} <- AB.Google.update_values(at, sid, "ledger!A1", [@ledger_headers]),
         {:ok, _} <- AB.Google.update_values(at, sid, "user!A1", [@user_headers]),
         {:ok, _} <- AB.Google.update_values(at, sid, "category!A1", [@cat_headers]),
         {:ok, _} <- AB.Google.update_values(at, sid, "object!A1", [@obj_headers]),
         seeds = AB.Categories.seed_rows(),
         {:ok, _} <- AB.Google.append_values(at, sid, "category!A1", seeds) do
      {:ok, sid}
    end
  end

  # Add user to the user tab
  def add_user(at, sid, chat_id, name, currency) do
    AB.Google.append_values(at, sid, "user!A1", [[chat_id, name, currency]])
  end

  # Load categories from sheet into a lookup map: %{name => %{id, parent_id, alias_id}}
  def load_categories(at, sid) do
    case AB.Google.read_values(at, sid, "category!A:D") do
      {:ok, [_header | rows]} ->
        map =
          rows
          |> Enum.reduce(%{}, fn row, acc ->
            [id, parent_id, alias_id, name] = pad(row, 4)
            Map.put(acc, name, %{id: id, parent_id: parent_id, alias_id: alias_id})
          end)

        {:ok, map}

      {:ok, _} ->
        {:ok, %{}}

      err ->
        err
    end
  end

  # Load objects from sheet
  def load_objects(at, sid) do
    case AB.Google.read_values(at, sid, "object!A:C") do
      {:ok, [_header | rows]} ->
        map =
          rows
          |> Enum.reduce(%{}, fn row, acc ->
            [id, alias_id, name] = pad(row, 3)
            Map.put(acc, name, %{id: id, alias_id: alias_id})
          end)

        {:ok, map}

      {:ok, _} ->
        {:ok, %{}}

      err ->
        err
    end
  end

  # Append a ledger entry
  def append_ledger(at, sid, entry) do
    row = [
      entry[:date],
      entry[:user],
      entry[:type],
      entry[:category],
      entry[:subcategory] || "",
      entry[:amount],
      entry[:currency],
      entry[:object] || "",
      entry[:note] || ""
    ]

    AB.Google.append_values(at, sid, "ledger!A1", [row])
  end

  # Read ledger rows (returns list of maps)
  def read_ledger(at, sid) do
    case AB.Google.read_values(at, sid, "ledger!A:I") do
      {:ok, [_header | rows]} ->
        entries =
          rows
          |> Enum.with_index(2)
          |> Enum.map(fn {row, idx} ->
            cols = pad(row, 9)

            %{
              row: idx,
              date: Enum.at(cols, 0),
              user: Enum.at(cols, 1),
              type: Enum.at(cols, 2),
              category: Enum.at(cols, 3),
              subcategory: Enum.at(cols, 4),
              amount: Enum.at(cols, 5),
              currency: Enum.at(cols, 6),
              object: Enum.at(cols, 7),
              note: Enum.at(cols, 8)
            }
          end)

        {:ok, entries}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  # Get user's default currency from user tab
  def get_user_currency(at, sid, chat_id) do
    case AB.Google.read_values(at, sid, "user!A:C") do
      {:ok, [_header | rows]} ->
        cid = to_string(chat_id)

        case Enum.find(rows, fn row -> List.first(row) == cid end) do
          nil -> nil
          row -> Enum.at(row, 2, "TWD")
        end

      _ ->
        nil
    end
  end

  # Find ledger sheet GID (for delete_row)
  def ledger_gid(at, sid) do
    case AB.Google.get_sheet_meta(at, sid) do
      {:ok, %{"sheets" => sheets}} ->
        sheet = Enum.find(sheets, fn s -> get_in(s, ["properties", "title"]) == "ledger" end)
        if sheet, do: {:ok, get_in(sheet, ["properties", "sheetId"])}, else: {:error, :not_found}

      err ->
        err
    end
  end

  defp pad(list, n) do
    list ++ List.duplicate("", max(0, n - length(list)))
  end
end

# ===========================================================================
# Parser — freeform text → transaction
# ===========================================================================
defmodule AB.Parser do
  # Parse: [YYYYMMDD] <category> [object] <amount>[元]
  # Returns {:ok, %{date:, category:, object:, amount:}} or :error
  def parse(text, category_names) do
    text = String.trim(text)
    # Build pattern: optional date, category (matched from known names), optional object, amount
    # We try each known category name as a prefix match
    case try_parse(text, category_names) do
      nil -> :error
      result -> {:ok, result}
    end
  end

  defp try_parse(text, category_names) do
    # Try with date prefix first
    {date, rest} = extract_date(text)

    # Sort category names longest first to match greedily
    sorted = category_names |> Enum.sort_by(&(-String.length(&1)))

    Enum.find_value(sorted, fn cat ->
      if String.starts_with?(rest, cat) do
        after_cat = rest |> String.slice(String.length(cat)..-1//1) |> String.trim()
        parse_after_category(date, cat, after_cat)
      end
    end)
  end

  defp extract_date(text) do
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})\s+(.+)$/u, text) do
      [_, y, m, d, rest] -> {"#{y}-#{m}-#{d}", rest}
      _ -> {today_str(), text}
    end
  end

  defp parse_after_category(date, category, rest) do
    # rest is: [object] <amount>[元]
    case Regex.run(~r/^(.*\D)\s*(\d+)元?$/u, rest) do
      [_, obj, amount] ->
        %{date: date, category: category, object: String.trim(obj), amount: String.to_integer(amount)}

      _ ->
        # Try just amount
        case Regex.run(~r/^(\d+)元?$/u, rest) do
          [_, amount] ->
            %{date: date, category: category, object: "", amount: String.to_integer(amount)}

          _ ->
            nil
        end
    end
  end

  def today_str do
    {{y, m, d}, _} = :calendar.local_time()
    :io_lib.format("~4..0B-~2..0B-~2..0B", [y, m, d]) |> to_string()
  end
end

# ===========================================================================
# Handler — command & callback routing
# ===========================================================================
defmodule AB.Handler do
  # --- Locale ---

  def locale(update) do
    lang =
      get_in(update, ["message", "from", "language_code"]) ||
        get_in(update, ["callback_query", "from", "language_code"]) || "en"

    if String.starts_with?(lang, "zh"), do: :zh, else: :en
  end

  # --- Category cache (per spreadsheet) ---
  # Simple process dictionary cache with TTL

  defp cached_categories(at, sid) do
    key = {:cat_cache, sid}

    case Process.get(key) do
      {cats, ts} when is_map(cats) ->
        if System.monotonic_time(:second) - ts < 300 do
          cats
        else
          reload_categories(at, sid, key)
        end

      _ ->
        reload_categories(at, sid, key)
    end
  end

  defp reload_categories(at, sid, key) do
    case AB.Sheets.load_categories(at, sid) do
      {:ok, cats} ->
        Process.put(key, {cats, System.monotonic_time(:second)})
        cats

      _ ->
        %{}
    end
  end

  def invalidate_cat_cache(sid) do
    Process.delete({:cat_cache, sid})
  end

  # --- Recent usage tracking (per spreadsheet) ---
  # Simple process dictionary cache with TTL

  defp get_recent_usage(at, sid) do
    key = {:recent_usage, sid}

    case Process.get(key) do
      {usage, ts} when is_map(usage) ->
        if System.monotonic_time(:second) - ts < 60 do
          usage
        else
          reload_recent_usage(at, sid, key)
        end

      _ ->
        reload_recent_usage(at, sid, key)
    end
  end

  defp reload_recent_usage(at, sid, key) do
    case AB.Google.read_values(at, sid, "ledger!D2:E") do
      {:ok, rows} when is_list(rows) ->
        usage_map =
          rows
          |> Enum.with_index()
          |> Enum.reduce(%{}, fn {row, idx}, acc ->
            case row do
              [cat, sub | _] ->
                acc = if cat != "" and cat != nil, do: Map.put(acc, cat, idx), else: acc
                if sub != "" and sub != nil, do: Map.put(acc, sub, idx), else: acc

              [cat] ->
                if cat != "" and cat != nil, do: Map.put(acc, cat, idx), else: acc

              _ ->
                acc
            end
          end)

        Process.put(key, {usage_map, System.monotonic_time(:second)})
        usage_map

      _ ->
        %{}
    end
  end

  defp sort_by_recent(names, at, sid) do
    usage_map = get_recent_usage(at, sid)

    names
    |> Enum.sort(fn a, b ->
      score_a = Map.get(usage_map, a, -1)
      score_b = Map.get(usage_map, b, -1)

      if score_a != score_b do
        score_a > score_b
      else
        a < b
      end
    end)
  end

  # --- Resolve category name (handle aliases) ---

  defp resolve_category(name, cats) do
    case Map.get(cats, name) do
      %{alias_id: aid} when aid != "" and aid != nil ->
        # Find the target by id
        case Enum.find(cats, fn {_n, %{id: id}} -> to_string(id) == to_string(aid) end) do
          {target_name, _} -> target_name
          nil -> name
        end

      _ ->
        name
    end
  end

  # Determine if a category name is income
  defp income_category?(name) do
    income_names = AB.Categories.income() |> Map.values() |> MapSet.new()
    MapSet.member?(income_names, name)
  end

  # Get parent category for a subcategory
  defp parent_category(name, cats) do
    case Map.get(cats, name) do
      %{parent_id: pid} when pid != "" and pid != nil ->
        case Enum.find(cats, fn {_n, %{id: id}} -> to_string(id) == to_string(pid) end) do
          {parent_name, _} -> parent_name
          nil -> nil
        end

      _ ->
        nil
    end
  end

  # Get subcategories for a parent
  defp subcategories(parent_name, cats) do
    parent_info = Map.get(cats, parent_name)

    if parent_info do
      pid = parent_info.id

      cats
      |> Enum.filter(fn {_name, info} ->
        to_string(info.parent_id) == to_string(pid) and
          (info.alias_id == "" or info.alias_id == nil)
      end)
      |> Enum.map(fn {name, _} -> name end)
      |> Enum.sort()
    else
      []
    end
  end

  # Top-level categories (no parent, no alias)
  defp top_categories(cats) do
    cats
    |> Enum.filter(fn {_name, info} ->
      (info.parent_id == "" or info.parent_id == nil) and
        (info.alias_id == "" or info.alias_id == nil)
    end)
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.sort()
  end

  # --- Main dispatch ---

  def handle(update, config) do
    cond do
      update["message"] ->
        handle_message(update, config)

      update["callback_query"] ->
        handle_callback(update, config)

      true ->
        :ok
    end
  end

  # --- Message handling ---

  defp handle_message(update, config) do
    msg = update["message"]
    chat_id = msg["chat"]["id"]
    text = (msg["text"] || "") |> String.trim()
    user_name = msg["from"]["first_name"] || msg["from"]["username"] || "user"

    conv = AB.Conv.get(chat_id)

    cond do
      # Commands
      String.starts_with?(text, "/start") -> cmd_start(chat_id, user_name, config, update)
      String.starts_with?(text, "/help") -> cmd_help(chat_id, config, update)
      String.starts_with?(text, "/input") -> cmd_input(chat_id, config, update)
      String.starts_with?(text, "/list") -> cmd_list(chat_id, config, update)
      String.starts_with?(text, "/edit") -> cmd_edit(chat_id, config, update)
      String.starts_with?(text, "/delete") -> cmd_delete(chat_id, config, update)
      String.starts_with?(text, "/invite") -> cmd_invite(chat_id, text, config, update)

      # Conversation state handlers
      conv.state == :awaiting_oauth -> handle_oauth_code(chat_id, text, user_name, config, update)
      conv.state == :awaiting_currency -> handle_currency(chat_id, text, config, update)
      conv.state == :awaiting_sheet_name -> handle_sheet_name(chat_id, text, config, update)
      conv.state in [:input_amount, :input_object, :input_note] -> handle_input_text(chat_id, text, conv, config, update)
      conv.state == :edit_value -> handle_edit_value(chat_id, text, conv, config, update)

      # Freeform text parse
      text != "" -> handle_freeform(chat_id, text, user_name, config, update)

      true -> :ok
    end
  end

  # --- /start ---

  defp cmd_start(chat_id, user_name, config, update) do
    token = config["telegram_token"]
    loc = locale(update)

    case AB.State.get_user(chat_id) do
      %{"spreadsheet_id" => sid} when is_binary(sid) ->
        msg =
          case loc do
            :zh -> "✅ 已連結試算表。\n📊 Sheet ID: <code>#{sid}</code>\n\n使用 /help 查看指令。"
            _ -> "✅ Already linked to a spreadsheet.\n📊 Sheet ID: <code>#{sid}</code>\n\nUse /help to see commands."
          end

        AB.Telegram.send_msg(token, chat_id, msg)

      _ ->
        url = AB.Google.auth_url(config)

        msg =
          case loc do
            :zh ->
              "👋 歡迎！讓我們連接你的 Google 帳戶。\n\n" <>
                "1️⃣ 開啟此連結並登入 Google：\n#{url}\n\n" <>
                "2️⃣ 授權後，從網址列複製 <code>code=</code> 後面的授權碼\n\n" <>
                "3️⃣ 將授權碼貼到這裡"

            _ ->
              "👋 Welcome! Let's connect your Google account.\n\n" <>
                "1️⃣ Open this link and sign in to Google:\n#{url}\n\n" <>
                "2️⃣ After authorizing, copy the authorization code from the URL bar (after <code>code=</code>)\n\n" <>
                "3️⃣ Paste the code here"
          end

        AB.Telegram.send_msg(token, chat_id, msg)
        AB.Conv.put(chat_id, %{state: :awaiting_oauth, user_name: user_name})
    end
  end

  # --- OAuth code handler ---

  defp handle_oauth_code(chat_id, code, user_name, config, update) do
    token = config["telegram_token"]
    loc = locale(update)

    # Clean code: user might paste URL like http://localhost/?code=XXX&scope=...
    code =
      cond do
        String.contains?(code, "code=") ->
          code |> String.split("code=") |> List.last() |> String.split("&") |> List.first()

        true ->
          code
      end

    case AB.Google.exchange_code(config, code) do
      {:ok, tokens} ->
        AB.State.put_user(chat_id, %{
          "google_tokens" => tokens,
          "role" => "owner",
          "spreadsheet_id" => nil
        })

        msg =
          case loc do
            :zh -> "✅ Google 帳戶已連接！\n\n請輸入試算表名稱（預設: <b>AccountBot</b>）："
            _ -> "✅ Google account connected!\n\nEnter spreadsheet name (default: <b>AccountBot</b>):"
          end

        AB.Telegram.send_msg(token, chat_id, msg)
        AB.Conv.put(chat_id, %{state: :awaiting_sheet_name, user_name: user_name})

      {:error, err} ->
        msg =
          case loc do
            :zh -> "❌ 授權失敗：#{inspect(err)}\n\n請重新 /start"
            _ -> "❌ Authorization failed: #{inspect(err)}\n\nPlease try /start again"
          end

        AB.Telegram.send_msg(token, chat_id, msg)
        AB.Conv.reset(chat_id)
    end
  end

  # --- Sheet name handler ---

  defp handle_sheet_name(chat_id, text, config, update) do
    token = config["telegram_token"]
    loc = locale(update)
    conv = AB.Conv.get(chat_id)
    user_name = conv[:user_name] || "user"
    sheet_name = if text == "", do: "AccountBot", else: text

    case AB.Google.access_token(config, chat_id) do
      {:ok, at} ->
        # Search for existing sheet
        msg_searching =
          case loc do
            :zh -> "🔍 搜尋「#{sheet_name}」..."
            _ -> "🔍 Searching for \"#{sheet_name}\"..."
          end

        AB.Telegram.send_msg(token, chat_id, msg_searching)

        case AB.Google.find_spreadsheet(at, sheet_name) do
          {:ok, [first | _]} ->
            sid = first["id"]
            AB.State.put_user(chat_id, Map.merge(AB.State.get_user(chat_id), %{"spreadsheet_id" => sid}))

            msg =
              case loc do
                :zh -> "📊 已找到試算表「#{sheet_name}」！已連結。\n\n請輸入預設幣別（例如 TWD, JPY, USD）："
                _ -> "📊 Found spreadsheet \"#{sheet_name}\"! Linked.\n\nEnter default currency (e.g., TWD, JPY, USD):"
              end

            AB.Telegram.send_msg(token, chat_id, msg)
            AB.Conv.put(chat_id, %{state: :awaiting_currency, user_name: user_name})

          {:ok, []} ->
            # Create new sheet
            case AB.Sheets.create_account(at, sheet_name) do
              {:ok, sid} ->
                AB.State.put_user(chat_id, Map.merge(AB.State.get_user(chat_id), %{"spreadsheet_id" => sid}))

                msg =
                  case loc do
                    :zh -> "📝 已建立新試算表「#{sheet_name}」！\n\n請輸入預設幣別（例如 TWD, JPY, USD）："
                    _ -> "📝 Created new spreadsheet \"#{sheet_name}\"!\n\nEnter default currency (e.g., TWD, JPY, USD):"
                  end

                AB.Telegram.send_msg(token, chat_id, msg)
                AB.Conv.put(chat_id, %{state: :awaiting_currency, user_name: user_name})

              {:error, err} ->
                AB.Telegram.send_msg(token, chat_id, "❌ Failed to create sheet: #{inspect(err)}")
                AB.Conv.reset(chat_id)
            end

          {:error, err} ->
            AB.Telegram.send_msg(token, chat_id, "❌ Drive search failed: #{inspect(err)}")
            AB.Conv.reset(chat_id)
        end

      {:error, _} ->
        AB.Telegram.send_msg(token, chat_id, "❌ Token error. Please /start again.")
        AB.Conv.reset(chat_id)
    end
  end

  # --- Currency handler ---

  defp handle_currency(chat_id, text, config, update) do
    token = config["telegram_token"]
    loc = locale(update)
    conv = AB.Conv.get(chat_id)
    user_name = conv[:user_name] || "user"
    currency = text |> String.upcase() |> String.trim()
    currency = if currency == "", do: "TWD", else: currency

    case AB.Google.access_token(config, chat_id) do
      {:ok, at} ->
        sid = AB.State.get_sheet_id(chat_id)
        AB.Sheets.add_user(at, sid, chat_id, user_name, currency)

        msg =
          case loc do
            :zh ->
              "✅ 設定完成！預設幣別: <b>#{currency}</b>\n\n" <>
                "使用 /help 查看指令，或直接輸入如：\n<code>午餐 麥當勞 150</code>"

            _ ->
              "✅ Setup complete! Default currency: <b>#{currency}</b>\n\n" <>
                "Use /help for commands, or just type like:\n<code>午餐 麥當勞 150</code>"
          end

        AB.Telegram.send_msg(token, chat_id, msg)
        AB.Conv.reset(chat_id)

      {:error, _} ->
        AB.Telegram.send_msg(token, chat_id, "❌ Token error. Please /start again.")
        AB.Conv.reset(chat_id)
    end
  end

  # --- /help ---

  defp cmd_help(chat_id, config, update) do
    loc = locale(update)

    msg =
      case loc do
        :zh ->
          """
          📖 <b>指令列表</b>
          /start — 連接 Google 帳戶
          /input — 記帳（互動式）
          /list — 查看交易
          /edit — 編輯交易
          /delete — 刪除交易
          /invite @user — 邀請共用帳本
          /help — 顯示此說明

          💡 <b>快速輸入</b>（直接打字）：
          <code>午餐 麥當勞 150</code>
          <code>20260115 晚餐 壽司 800</code>
          <code>收入 薪水 50000</code>
          """

        _ ->
          """
          📖 <b>Commands</b>
          /start — Connect Google account
          /input — Record transaction (interactive)
          /list — View transactions
          /edit — Edit a transaction
          /delete — Delete a transaction
          /invite @user — Invite to share your account
          /help — Show this help

          💡 <b>Quick input</b> (just type):
          <code>午餐 麥當勞 150</code>
          <code>20260115 晚餐 壽司 800</code>
          <code>income 薪水 50000</code>
          """
      end

    AB.Telegram.send_msg(config["telegram_token"], chat_id, String.trim(msg))
  end

  # --- /input (interactive) ---

  defp cmd_input(chat_id, config, update) do
    token = config["telegram_token"]
    loc = locale(update)

    unless ensure_linked(chat_id, token, loc), do: throw(:not_linked)

    msg = case loc do
      :zh -> "收入或支出？"
      _ -> "Income or Expense?"
    end

    kb = %{
      inline_keyboard: [
        [
          %{text: "💸 #{if loc == :zh, do: "支出", else: "Expense"}", callback_data: "inp:type:expense"},
          %{text: "💰 #{if loc == :zh, do: "收入", else: "Income"}", callback_data: "inp:type:income"}
        ]
      ]
    }

    AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
    AB.Conv.put(chat_id, %{state: :input_type, data: %{}})
  catch
    :not_linked -> :ok
  end

  # --- /list ---

  defp cmd_list(chat_id, config, update) do
    token = config["telegram_token"]
    loc = locale(update)

    unless ensure_linked(chat_id, token, loc), do: throw(:not_linked)

    case AB.Google.access_token(config, chat_id) do
      {:ok, at} ->
        sid = AB.State.get_sheet_id(chat_id)

        case AB.Sheets.read_ledger(at, sid) do
          {:ok, entries} ->
            # Filter to current month
            {{y, m, _}, _} = :calendar.local_time()
            prefix = :io_lib.format("~4..0B-~2..0B", [y, m]) |> to_string()

            month_entries =
              entries
              |> Enum.filter(&String.starts_with?(&1.date || "", prefix))
              |> Enum.reverse()

            if month_entries == [] do
              msg = case loc do
                :zh -> "📋 本月尚無交易記錄。"
                _ -> "📋 No transactions this month."
              end
              AB.Telegram.send_msg(token, chat_id, msg)
            else
              send_list_page(chat_id, token, loc, month_entries, 0, prefix)
            end

          {:error, err} ->
            AB.Telegram.send_msg(token, chat_id, "❌ #{inspect(err)}")
        end

      {:error, _} ->
        AB.Telegram.send_msg(token, chat_id, "❌ Token error. /start to reconnect.")
    end
  catch
    :not_linked -> :ok
  end

  defp send_list_page(chat_id, token, loc, entries, page, month_prefix) do
    page_size = 10
    total_pages = max(1, ceil(length(entries) / page_size))
    page_entries = Enum.slice(entries, page * page_size, page_size)

    total_expense =
      entries
      |> Enum.filter(&(&1.type == "expense"))
      |> Enum.map(&parse_amount(&1.amount))
      |> Enum.sum()

    total_income =
      entries
      |> Enum.filter(&(&1.type == "income"))
      |> Enum.map(&parse_amount(&1.amount))
      |> Enum.sum()

    header =
      case loc do
        :zh -> "📊 #{month_prefix} — #{length(entries)} 筆"
        _ -> "📊 #{month_prefix} — #{length(entries)} entries"
      end

    lines =
      page_entries
      |> Enum.with_index(page * page_size + 1)
      |> Enum.map(fn {e, i} ->
        icon = if e.type == "income", do: "💰", else: "💸"
        obj = if e.object != "", do: " #{e.object}", else: ""
        "#{i}. #{String.slice(e.date || "", 5..9)} #{icon} #{e.category}#{obj} #{e.amount} #{e.currency}"
      end)

    summary =
      case loc do
        :zh -> "\n💸 支出: #{total_expense}  💰 收入: #{total_income}  淨: #{total_income - total_expense}"
        _ -> "\n💸 Expense: #{total_expense}  💰 Income: #{total_income}  Net: #{total_income - total_expense}"
      end

    text = header <> "\n\n" <> Enum.join(lines, "\n") <> "\n" <> summary

    nav =
      []
      |> then(fn btns -> if page > 0, do: [%{text: "◀", callback_data: "lst:page:#{page - 1}"} | btns], else: btns end)
      |> then(fn btns -> btns ++ [%{text: "#{page + 1}/#{total_pages}", callback_data: "lst:noop"}] end)
      |> then(fn btns -> if page < total_pages - 1, do: btns ++ [%{text: "▶", callback_data: "lst:page:#{page + 1}"}], else: btns end)

    kb = %{inline_keyboard: [nav]}
    AB.Telegram.send_msg(token, chat_id, text, reply_markup: kb)

    # Store entries in conv for pagination
    AB.Conv.put(chat_id, %{state: :list_view, entries: entries, month: month_prefix, page: page})
  end

  defp parse_amount(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error ->
        case Float.parse(s) do
          {f, _} -> round(f)
          :error -> 0
        end
    end
  end

  defp parse_amount(n) when is_number(n), do: n
  defp parse_amount(_), do: 0

  # --- /edit ---

  defp cmd_edit(chat_id, config, update) do
    token = config["telegram_token"]
    loc = locale(update)

    unless ensure_linked(chat_id, token, loc), do: throw(:not_linked)

    case AB.Google.access_token(config, chat_id) do
      {:ok, at} ->
        sid = AB.State.get_sheet_id(chat_id)

        case AB.Sheets.read_ledger(at, sid) do
          {:ok, entries} ->
            recent = entries |> Enum.reverse() |> Enum.take(10)

            if recent == [] do
              msg = case loc do
                :zh -> "📋 沒有可編輯的記錄。"
                _ -> "📋 No entries to edit."
              end
              AB.Telegram.send_msg(token, chat_id, msg)
            else
              msg = case loc do
                :zh -> "✏️ 選擇要編輯的記錄："
                _ -> "✏️ Select entry to edit:"
              end

              buttons =
                recent
                |> Enum.map(fn e ->
                  icon = if e.type == "income", do: "💰", else: "💸"
                  obj = if e.object != "", do: " #{e.object}", else: ""
                  label = "#{String.slice(e.date || "", 5..9)} #{icon} #{e.category}#{obj} #{e.amount}"
                  [%{text: label, callback_data: "edt:sel:#{e.row}"}]
                end)

              kb = %{inline_keyboard: buttons}
              AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
              AB.Conv.put(chat_id, %{state: :edit_select, entries: recent})
            end

          {:error, err} ->
            AB.Telegram.send_msg(token, chat_id, "❌ #{inspect(err)}")
        end

      {:error, _} ->
        AB.Telegram.send_msg(token, chat_id, "❌ Token error. /start to reconnect.")
    end
  catch
    :not_linked -> :ok
  end

  # --- /delete ---

  defp cmd_delete(chat_id, config, update) do
    token = config["telegram_token"]
    loc = locale(update)

    unless ensure_linked(chat_id, token, loc), do: throw(:not_linked)

    case AB.Google.access_token(config, chat_id) do
      {:ok, at} ->
        sid = AB.State.get_sheet_id(chat_id)

        case AB.Sheets.read_ledger(at, sid) do
          {:ok, entries} ->
            recent = entries |> Enum.reverse() |> Enum.take(10)

            if recent == [] do
              msg = case loc do
                :zh -> "📋 沒有可刪除的記錄。"
                _ -> "📋 No entries to delete."
              end
              AB.Telegram.send_msg(token, chat_id, msg)
            else
              msg = case loc do
                :zh -> "🗑️ 選擇要刪除的記錄："
                _ -> "🗑️ Select entry to delete:"
              end

              buttons =
                recent
                |> Enum.map(fn e ->
                  icon = if e.type == "income", do: "💰", else: "💸"
                  obj = if e.object != "", do: " #{e.object}", else: ""
                  label = "#{String.slice(e.date || "", 5..9)} #{icon} #{e.category}#{obj} #{e.amount}"
                  [%{text: label, callback_data: "del:sel:#{e.row}"}]
                end)

              kb = %{inline_keyboard: buttons}
              AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
              AB.Conv.put(chat_id, %{state: :delete_select, entries: recent})
            end

          {:error, err} ->
            AB.Telegram.send_msg(token, chat_id, "❌ #{inspect(err)}")
        end

      {:error, _} ->
        AB.Telegram.send_msg(token, chat_id, "❌ Token error. /start to reconnect.")
    end
  catch
    :not_linked -> :ok
  end

  # --- /invite ---

  defp cmd_invite(chat_id, text, config, update) do
    token = config["telegram_token"]
    loc = locale(update)

    unless ensure_linked(chat_id, token, loc), do: throw(:not_linked)

    # Parse: /invite @username or /invite chat_id
    parts = String.split(text, ~r/\s+/, parts: 2)

    case parts do
      ["/invite", target] ->
        msg =
          case loc do
            :zh ->
              "👋 已發送邀請。請讓 #{target} 在此群組中發送任意訊息，" <>
                "然後使用 /invite 指令再次邀請，或請他們直接向我發送 /start。\n\n" <>
                "（目前的簡化版本：請告知被邀請者的 chat_id）"

            _ ->
              "👋 Invite sent. In the simplified version, please provide the invitee's chat_id.\n" <>
                "The invitee doesn't need Google OAuth — they'll use your account."
          end

        AB.Telegram.send_msg(token, chat_id, msg)

      _ ->
        msg = case loc do
          :zh -> "用法: /invite @username"
          _ -> "Usage: /invite @username"
        end
        AB.Telegram.send_msg(token, chat_id, msg)
    end
  catch
    :not_linked -> :ok
  end

  # --- Freeform text parse ---

  defp handle_freeform(chat_id, text, user_name, config, update) do
    token = config["telegram_token"]
    loc = locale(update)

    sid = AB.State.get_sheet_id(chat_id)
    unless sid, do: throw(:not_linked_silent)

    case AB.Google.access_token(config, chat_id) do
      {:ok, at} ->
        cats = cached_categories(at, sid)
        cat_names = Map.keys(cats)

        case AB.Parser.parse(text, cat_names) do
          {:ok, parsed} ->
            resolved = resolve_category(parsed.category, cats)
            parent = parent_category(resolved, cats)
            is_income = income_category?(resolved) || income_category?(parent || "")

            {category, subcategory} =
              if parent do
                {parent, resolved}
              else
                {resolved, ""}
              end

            type = if is_income, do: "income", else: "expense"
            currency = AB.Sheets.get_user_currency(at, sid, chat_id) || "TWD"

            entry = %{
              date: parsed.date,
              user: user_name,
              type: type,
              category: category,
              subcategory: subcategory,
              amount: parsed.amount,
              currency: currency,
              object: parsed.object,
              note: ""
            }

            icon = if type == "income", do: "💰", else: "💸"
            obj_str = if entry.object != "", do: " #{entry.object}", else: ""
            sub_str = if subcategory != "", do: "/#{subcategory}", else: ""

            msg =
              case loc do
                :zh ->
                  "#{icon} #{entry.date} #{category}#{sub_str}#{obj_str} #{entry.amount} #{currency}\n確認記帳？"

                _ ->
                  "#{icon} #{entry.date} #{category}#{sub_str}#{obj_str} #{entry.amount} #{currency}\nConfirm?"
              end

            kb = %{
              inline_keyboard: [
                [
                  %{text: "✅", callback_data: "inp:confirm"},
                  %{text: "❌", callback_data: "inp:cancel"}
                ]
              ]
            }

            AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
            AB.Conv.put(chat_id, %{state: :input_confirm, data: entry})

          :error ->
            # Not parseable, ignore silently
            :ok
        end

      {:error, _} ->
        :ok
    end
  catch
    :not_linked_silent -> :ok
  end

  # --- Input text handlers (for interactive flow steps) ---

  defp handle_input_text(chat_id, text, conv, config, update) do
    token = config["telegram_token"]
    loc = locale(update)
    data = conv.data || %{}

    case conv.state do
      :input_amount ->
        case Integer.parse(text) do
          {amount, _} when amount > 0 ->
            data = Map.put(data, :amount, amount)

            msg = case loc do
              :zh -> "🏪 商家/對象？（輸入名稱或按跳過）"
              _ -> "🏪 Merchant/object? (type name or skip)"
            end

            kb = %{inline_keyboard: [[%{text: case loc do :zh -> "跳過"; _ -> "Skip" end, callback_data: "inp:skip_obj"}]]}
            AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
            AB.Conv.put(chat_id, %{state: :input_object, data: data})

          _ ->
            msg = case loc do
              :zh -> "❌ 請輸入有效金額（正整數）"
              _ -> "❌ Please enter a valid amount (positive integer)"
            end
            AB.Telegram.send_msg(token, chat_id, msg)
        end

      :input_object ->
        data = Map.put(data, :object, text)

        msg = case loc do
          :zh -> "📝 備註？（輸入內容或按跳過）"
          _ -> "📝 Note? (type or skip)"
        end

        kb = %{inline_keyboard: [[%{text: case loc do :zh -> "跳過"; _ -> "Skip" end, callback_data: "inp:skip_note"}]]}
        AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
        AB.Conv.put(chat_id, %{state: :input_note, data: data})

      :input_note ->
        data = Map.put(data, :note, text)
        do_save_entry(chat_id, data, config, update)

      _ ->
        :ok
    end
  end

  # --- Edit value handler ---

  defp handle_edit_value(chat_id, text, conv, config, _update) do
    token = config["telegram_token"]
    entry = conv[:entry]
    field = conv[:field]
    row = entry.row

    new_value =
      case field do
        "amount" ->
          case Integer.parse(text) do
            {n, _} -> n
            _ -> text
          end
        _ -> text
      end

    # Map field name to column index
    col_map = %{
      "date" => 0, "type" => 2, "category" => 3, "subcategory" => 4,
      "amount" => 5, "currency" => 6, "object" => 7, "note" => 8
    }

    col = col_map[field]

    if col do
      case AB.Google.access_token(config, chat_id) do
        {:ok, at} ->
          sid = AB.State.get_sheet_id(chat_id)
          col_letter = Enum.at(~w(A B C D E F G H I), col)
          range = "ledger!#{col_letter}#{row}"
          AB.Google.update_values(at, sid, range, [[new_value]])
          AB.Telegram.send_msg(token, chat_id, "✅ Updated #{field} → #{new_value}")
          AB.Conv.reset(chat_id)

        {:error, _} ->
          AB.Telegram.send_msg(token, chat_id, "❌ Token error.")
          AB.Conv.reset(chat_id)
      end
    else
      AB.Telegram.send_msg(token, chat_id, "❌ Unknown field.")
      AB.Conv.reset(chat_id)
    end
  end

  # --- Callback query handling ---

  defp handle_callback(update, config) do
    cb = update["callback_query"]
    chat_id = cb["message"]["chat"]["id"]
    msg_id = cb["message"]["message_id"]
    data = cb["data"]
    token = config["telegram_token"]

    AB.Telegram.answer_cb(token, cb["id"])

    cond do
      String.starts_with?(data, "inp:") -> handle_input_cb(chat_id, msg_id, data, config, update)
      String.starts_with?(data, "lst:") -> handle_list_cb(chat_id, msg_id, data, config, update)
      String.starts_with?(data, "edt:") -> handle_edit_cb(chat_id, msg_id, data, config, update)
      String.starts_with?(data, "del:") -> handle_delete_cb(chat_id, msg_id, data, config, update)
      true -> :ok
    end
  end

  # --- Input callbacks ---

  defp handle_input_cb(chat_id, _msg_id, data, config, update) do
    token = config["telegram_token"]
    loc = locale(update)
    conv = AB.Conv.get(chat_id)
    conv_data = conv[:data] || %{}

    case data do
      "inp:type:" <> type ->
        conv_data = Map.put(conv_data, :type, type)

        case AB.Google.access_token(config, chat_id) do
          {:ok, at} ->
            sid = AB.State.get_sheet_id(chat_id)
            cats = cached_categories(at, sid)
            top = top_categories(cats) |> sort_by_recent(at, sid)
            send_category_page(chat_id, token, loc, top, 0, "inp")
            AB.Conv.put(chat_id, %{state: :input_category, data: conv_data, categories: top})

          {:error, _} ->
            AB.Telegram.send_msg(token, chat_id, "❌ Token error.")
            AB.Conv.reset(chat_id)
        end

      "inp:cat:" <> cat_name ->
        # Check if this category has subcategories
        case AB.Google.access_token(config, chat_id) do
          {:ok, at} ->
            sid = AB.State.get_sheet_id(chat_id)
            cats = cached_categories(at, sid)
            subs = subcategories(cat_name, cats) |> sort_by_recent(at, sid)

            if subs != [] do
              conv_data = Map.put(conv_data, :category, cat_name)
              send_category_page(chat_id, token, loc, subs, 0, "inp:sub")

              # skip button is already in the page via the sub prefix handler
              AB.Conv.put(chat_id, %{state: :input_subcategory, data: conv_data, subcategories: subs})
            else
              conv_data = Map.put(conv_data, :category, cat_name)
              ask_amount(chat_id, token, loc, conv_data)
            end

          {:error, _} ->
            AB.Telegram.send_msg(token, chat_id, "❌ Token error.")
            AB.Conv.reset(chat_id)
        end

      "inp:sub:" <> sub_name ->
        conv_data = Map.put(conv_data, :subcategory, sub_name)
        ask_amount(chat_id, token, loc, conv_data)

      "inp:skip_sub" ->
        ask_amount(chat_id, token, loc, conv_data)

      "inp:page:" <> page_str ->
        page = String.to_integer(page_str)
        items = conv[:categories] || conv[:subcategories] || []
        prefix = if conv.state == :input_subcategory, do: "inp:sub", else: "inp"
        send_category_page(chat_id, token, loc, items, page, prefix)

      "inp:subpage:" <> page_str ->
        page = String.to_integer(page_str)
        items = conv[:subcategories] || []
        send_category_page(chat_id, token, loc, items, page, "inp:sub")

      "inp:skip_obj" ->
        conv_data = Map.put(conv_data, :object, "")

        msg = case loc do
          :zh -> "📝 備註？（輸入內容或按跳過）"
          _ -> "📝 Note? (type or skip)"
        end

        kb = %{inline_keyboard: [[%{text: case loc do :zh -> "跳過"; _ -> "Skip" end, callback_data: "inp:skip_note"}]]}
        AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
        AB.Conv.put(chat_id, %{state: :input_note, data: conv_data})

      "inp:skip_note" ->
        conv_data = Map.put(conv_data, :note, "")
        do_save_entry(chat_id, conv_data, config, update)

      "inp:confirm" ->
        do_save_entry(chat_id, conv_data, config, update)

      "inp:cancel" ->
        msg = case loc do
          :zh -> "❌ 已取消。"
          _ -> "❌ Cancelled."
        end
        AB.Telegram.send_msg(token, chat_id, msg)
        AB.Conv.reset(chat_id)

      _ ->
        :ok
    end
  end

  defp ask_amount(chat_id, token, loc, data) do
    msg = case loc do
      :zh -> "💰 金額？"
      _ -> "💰 Amount?"
    end

    AB.Telegram.send_msg(token, chat_id, msg)
    AB.Conv.put(chat_id, %{state: :input_amount, data: data})
  end

  defp send_category_page(chat_id, token, loc, items, page, prefix) do
    page_size = 8
    total_pages = max(1, ceil(length(items) / page_size))
    page_items = Enum.slice(items, page * page_size, page_size)

    buttons =
      page_items
      |> Enum.chunk_every(2)
      |> Enum.map(fn chunk ->
        Enum.map(chunk, &%{text: &1, callback_data: "#{prefix}:cat:#{&1}"})
      end)

    # Add skip button for subcategories
    buttons =
      if String.contains?(prefix, "sub") do
        skip_label = case loc do :zh -> "跳過 ▶"; _ -> "Skip ▶" end
        buttons ++ [[%{text: skip_label, callback_data: "inp:skip_sub"}]]
      else
        buttons
      end

    # Nav row
    nav_prefix = if String.contains?(prefix, "sub"), do: "inp:subpage", else: "inp:page"
    nav = []
    nav = if page > 0, do: [%{text: "◀", callback_data: "#{nav_prefix}:#{page - 1}"} | nav], else: nav
    nav = nav ++ [%{text: "#{page + 1}/#{total_pages}", callback_data: "lst:noop"}]
    nav = if page < total_pages - 1, do: nav ++ [%{text: "▶", callback_data: "#{nav_prefix}:#{page + 1}"}], else: nav

    buttons = if total_pages > 1, do: buttons ++ [nav], else: buttons

    msg = case loc do
      :zh -> "📁 選擇分類："
      _ -> "📁 Select category:"
    end

    kb = %{inline_keyboard: buttons}
    AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
  end

  # --- Save entry ---

  defp do_save_entry(chat_id, data, config, update) do
    token = config["telegram_token"]

    case AB.Google.access_token(config, chat_id) do
      {:ok, at} ->
        sid = AB.State.get_sheet_id(chat_id)

        # Fill in defaults
        from = get_in(update, ["callback_query", "from"]) || get_in(update, ["message", "from"]) || %{}
        user_name = data[:user] || from["first_name"] || "user"
        currency = data[:currency] || AB.Sheets.get_user_currency(at, sid, chat_id) || "TWD"
        date = data[:date] || AB.Parser.today_str()

        entry = %{
          date: date,
          user: user_name,
          type: data[:type] || "expense",
          category: data[:category] || "",
          subcategory: data[:subcategory] || "",
          amount: data[:amount] || 0,
          currency: currency,
          object: data[:object] || "",
          note: data[:note] || ""
        }

        case AB.Sheets.append_ledger(at, sid, entry) do
          {:ok, _} ->
            icon = if entry.type == "income", do: "💰", else: "💸"
            obj_str = if entry.object != "", do: " #{entry.object}", else: ""
            sub_str = if entry.subcategory != "", do: "/#{entry.subcategory}", else: ""

            msg = "✅ #{icon} #{entry.date} #{entry.category}#{sub_str}#{obj_str} #{entry.amount} #{entry.currency}"
            AB.Telegram.send_msg(token, chat_id, msg)

          {:error, err} ->
            AB.Telegram.send_msg(token, chat_id, "❌ Save failed: #{inspect(err)}")
        end

        AB.Conv.reset(chat_id)

      {:error, _} ->
        AB.Telegram.send_msg(token, chat_id, "❌ Token error.")
        AB.Conv.reset(chat_id)
    end
  end

  # --- List callbacks ---

  defp handle_list_cb(chat_id, _msg_id, data, config, update) do
    token = config["telegram_token"]
    loc = locale(update)
    conv = AB.Conv.get(chat_id)

    case data do
      "lst:page:" <> page_str ->
        page = String.to_integer(page_str)
        entries = conv[:entries] || []
        month = conv[:month] || ""
        send_list_page(chat_id, token, loc, entries, page, month)

      "lst:noop" ->
        :ok

      _ ->
        :ok
    end
  end

  # --- Edit callbacks ---

  defp handle_edit_cb(chat_id, _msg_id, data, config, update) do
    token = config["telegram_token"]
    loc = locale(update)
    conv = AB.Conv.get(chat_id)

    case data do
      "edt:sel:" <> row_str ->
        row = String.to_integer(row_str)
        entries = conv[:entries] || []
        entry = Enum.find(entries, &(&1.row == row))

        if entry do
          fields = [
            {"date", "📅 #{entry.date}"},
            {"type", (if entry.type == "income", do: "💰 income", else: "💸 expense")},
            {"category", "📁 #{entry.category}"},
            {"amount", "💰 #{entry.amount}"},
            {"currency", "💱 #{entry.currency}"},
            {"object", "🏪 #{entry.object || "—"}"},
            {"note", "📝 #{entry.note || "—"}"}
          ]

          buttons = Enum.map(fields, fn {field, label} ->
            [%{text: label, callback_data: "edt:field:#{field}:#{row}"}]
          end)

          buttons = buttons ++ [
            [
              %{text: "❌ #{if loc == :zh, do: "取消", else: "Cancel"}", callback_data: "edt:cancel"}
            ]
          ]

          msg = case loc do
            :zh -> "✏️ 點擊要修改的欄位："
            _ -> "✏️ Tap a field to edit:"
          end

          kb = %{inline_keyboard: buttons}
          AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
          AB.Conv.put(chat_id, %{state: :edit_field, entry: entry})
        end

      "edt:field:" <> rest ->
        [field, _row_str] = String.split(rest, ":", parts: 2)
        entry = conv[:entry]

        msg = case loc do
          :zh -> "輸入 #{field} 的新值："
          _ -> "Enter new value for #{field}:"
        end

        AB.Telegram.send_msg(token, chat_id, msg)
        AB.Conv.put(chat_id, %{state: :edit_value, entry: entry, field: field})

      "edt:cancel" ->
        msg = case loc do
          :zh -> "❌ 已取消。"
          _ -> "❌ Cancelled."
        end
        AB.Telegram.send_msg(token, chat_id, msg)
        AB.Conv.reset(chat_id)

      _ ->
        :ok
    end
  end

  # --- Delete callbacks ---

  defp handle_delete_cb(chat_id, _msg_id, data, config, update) do
    token = config["telegram_token"]
    loc = locale(update)
    conv = AB.Conv.get(chat_id)

    case data do
      "del:sel:" <> row_str ->
        row = String.to_integer(row_str)
        entries = conv[:entries] || []
        entry = Enum.find(entries, &(&1.row == row))

        if entry do
          icon = if entry.type == "income", do: "💰", else: "💸"
          obj = if entry.object != "", do: " #{entry.object}", else: ""
          label = "#{entry.date} #{icon} #{entry.category}#{obj} #{entry.amount} #{entry.currency}"

          msg = case loc do
            :zh -> "🗑️ 確定刪除「#{label}」？"
            _ -> "🗑️ Delete \"#{label}\"?"
          end

          kb = %{
            inline_keyboard: [
              [
                %{text: "✅ #{if loc == :zh, do: "確定", else: "Yes"}", callback_data: "del:yes:#{row}"},
                %{text: "❌ #{if loc == :zh, do: "取消", else: "No"}", callback_data: "del:no"}
              ]
            ]
          }

          AB.Telegram.send_msg(token, chat_id, msg, reply_markup: kb)
          AB.Conv.put(chat_id, %{state: :delete_confirm, entry: entry})
        end

      "del:yes:" <> row_str ->
        row = String.to_integer(row_str)

        case AB.Google.access_token(config, chat_id) do
          {:ok, at} ->
            sid = AB.State.get_sheet_id(chat_id)

            case AB.Sheets.ledger_gid(at, sid) do
              {:ok, gid} ->
                # row is 1-indexed in sheet, delete_row uses 0-indexed startIndex
                case AB.Google.delete_row(at, sid, gid, row - 1) do
                  {:ok, _} ->
                    msg = case loc do
                      :zh -> "✅ 已刪除。"
                      _ -> "✅ Deleted."
                    end
                    AB.Telegram.send_msg(token, chat_id, msg)

                  {:error, err} ->
                    AB.Telegram.send_msg(token, chat_id, "❌ #{inspect(err)}")
                end

              {:error, err} ->
                AB.Telegram.send_msg(token, chat_id, "❌ #{inspect(err)}")
            end

          {:error, _} ->
            AB.Telegram.send_msg(token, chat_id, "❌ Token error.")
        end

        AB.Conv.reset(chat_id)

      "del:no" ->
        msg = case loc do
          :zh -> "❌ 已取消。"
          _ -> "❌ Cancelled."
        end
        AB.Telegram.send_msg(token, chat_id, msg)
        AB.Conv.reset(chat_id)

      _ ->
        :ok
    end
  end

  # --- Helpers ---

  defp ensure_linked(chat_id, token, loc) do
    case AB.State.get_sheet_id(chat_id) do
      nil ->
        msg = case loc do
          :zh -> "⚠️ 尚未連結試算表。請先使用 /start"
          _ -> "⚠️ Not linked to a spreadsheet yet. Use /start first."
        end
        AB.Telegram.send_msg(token, chat_id, msg)
        false

      _ ->
        true
    end
  end
end

# ===========================================================================
# Import — --import CLI mode
# ===========================================================================
defmodule AB.Import do
  def run(args) do
    opts = parse_args(args)
    file = opts[:import] || raise "Missing --import FILE"
    sheet_id = opts[:sheet_id] || raise "Missing --sheet-id ID"
    chat_id = opts[:chat_id] || raise "Missing --chat-id ID"
    token_file = opts[:token_file] || "state.json"
    dry_run = opts[:dry_run] || false
    user_override = opts[:user]

    config = AB.Config.load()
    state = AB.State.load_file(token_file)
    tokens = get_in(state, ["users", to_string(chat_id), "google_tokens"])
    unless tokens, do: raise("No tokens found for chat_id #{chat_id} in #{token_file}")

    # Refresh token if needed
    {:ok, tokens} = AB.Google.access_token_raw(config, tokens)
    at = tokens["access_token"]

    # Determine user name
    user_name =
      user_override ||
        (case AB.Google.read_values(at, sheet_id, "user!A:C") do
           {:ok, [_ | rows]} ->
             case Enum.find(rows, &(List.first(&1) == to_string(chat_id))) do
               nil -> "import"
               row -> Enum.at(row, 1, "import")
             end

           _ ->
             "import"
         end)

    IO.puts("📂 Reading #{file}...")

    lines =
      File.stream!(file)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["active"] == 1))
      |> Enum.sort_by(& &1["date"])

    IO.puts("📊 Found #{length(lines)} active records")

    rows =
      Enum.map(lines, fn rec ->
        mode = rec["mode"]
        {cat, sub} = AB.Categories.resolve_zaim(mode, rec["category_id"], rec["genre_id"])
        type = if mode == "income", do: "income", else: "expense"

        [
          rec["date"],
          user_name,
          type,
          cat,
          sub,
          rec["amount"],
          rec["currency_code"] || "TWD",
          rec["place"] || "",
          rec["comment"] || ""
        ]
      end)

    expense_count = Enum.count(rows, fn r -> Enum.at(r, 2) == "expense" end)
    income_count = Enum.count(rows, fn r -> Enum.at(r, 2) == "income" end)
    date_from = rows |> List.first() |> Enum.at(0)
    date_to = rows |> List.last() |> Enum.at(0)

    if dry_run do
      IO.puts("\n🔍 DRY RUN — would import #{length(rows)} entries:")
      IO.puts("   💸 Expense: #{expense_count}")
      IO.puts("   💰 Income: #{income_count}")
      IO.puts("   📅 #{date_from} → #{date_to}")
      IO.puts("   👤 User: #{user_name}")
      IO.puts("\nFirst 5 rows:")

      rows
      |> Enum.take(5)
      |> Enum.each(fn r -> IO.puts("   #{inspect(r)}") end)
    else
      IO.puts("📝 Importing to sheet #{sheet_id}...")

      # Batch in chunks of 500
      rows
      |> Enum.chunk_every(500)
      |> Enum.with_index(1)
      |> Enum.each(fn {chunk, i} ->
        IO.puts("   Batch #{i}: #{length(chunk)} rows...")

        case AB.Google.append_values(at, sheet_id, "ledger!A1", chunk) do
          {:ok, _} -> IO.puts("   ✅ Batch #{i} done")
          {:error, err} -> IO.puts("   ❌ Batch #{i} failed: #{inspect(err)}")
        end
      end)

      IO.puts("\n✅ Imported #{length(rows)} entries (#{expense_count} expense, #{income_count} income)")
      IO.puts("   📅 #{date_from} → #{date_to}")
    end
  end

  defp parse_args(args) do
    parse_args(args, %{})
  end

  defp parse_args([], acc), do: acc

  defp parse_args(["--import", file | rest], acc),
    do: parse_args(rest, Map.put(acc, :import, file))

  defp parse_args(["--sheet-id", id | rest], acc),
    do: parse_args(rest, Map.put(acc, :sheet_id, id))

  defp parse_args(["--chat-id", id | rest], acc),
    do: parse_args(rest, Map.put(acc, :chat_id, id))

  defp parse_args(["--token-file", f | rest], acc),
    do: parse_args(rest, Map.put(acc, :token_file, f))

  defp parse_args(["--user", name | rest], acc),
    do: parse_args(rest, Map.put(acc, :user, name))

  defp parse_args(["--dry-run" | rest], acc),
    do: parse_args(rest, Map.put(acc, :dry_run, true))

  defp parse_args([_ | rest], acc),
    do: parse_args(rest, acc)
end

# ===========================================================================
# Main — entry point + polling loop
# ===========================================================================
defmodule AB.Main do
  def run(config) do
    token = config["telegram_token"]

    case AB.Telegram.get_me(token) do
      {:ok, me} ->
        IO.puts("🤖 Bot started: @#{me["username"]} (#{me["id"]})")
        AB.Telegram.set_my_commands(token)

      {:error, err} ->
        IO.puts("⚠️  get_me failed: #{inspect(err)}, continuing anyway...")
    end

    poll(config, token, 0)
  end

  defp poll(config, token, offset) do
    # Periodic cleanup of stale conversations
    AB.Conv.cleanup()

    updates = AB.Telegram.get_updates(token, offset)

    new_offset =
      Enum.reduce(updates, offset, fn update, _acc ->
        try do
          AB.Handler.handle(update, config)
        rescue
          e ->
            IO.puts("[ERROR] #{Exception.message(e)}")
            IO.puts(Exception.format(:error, e, __STACKTRACE__))
        end

        update["update_id"] + 1
      end)

    poll(config, token, new_offset)
  end
end

# ===========================================================================
# Entry point
# ===========================================================================
args = System.argv()

if Enum.member?(args, "--import") do
  AB.Import.run(args)
else
  config = AB.Config.load()
  {:ok, _} = AB.State.start_link()
  {:ok, _} = AB.Conv.start_link()
  AB.Main.run(config)
end
