defmodule LedgerBot.Bot.FSM do
  use GenServer
  require Logger

  @idle_ttl_ms 30 * 60 * 1000
  @recent_limit 5

  defstruct sessions: %{}, recents: %{}

  def start_link(_), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  def get(user_id, chat_id), do: GenServer.call(__MODULE__, {:get, user_id, chat_id})
  def put(user_id, chat_id, state, data \\ %{}), do: GenServer.cast(__MODULE__, {:put, user_id, chat_id, state, data})
  def reset(user_id, chat_id), do: GenServer.cast(__MODULE__, {:put, user_id, chat_id, "idle", %{}})
  def set_book(user_id, chat_id, book_id), do: GenServer.cast(__MODULE__, {:set_book, user_id, chat_id, book_id})
  def get_book(user_id, chat_id), do: GenServer.call(__MODULE__, {:get_book, user_id, chat_id})
  def push_recent(user_id, entry), do: GenServer.cast(__MODULE__, {:push_recent, user_id, entry})
  def get_recents(user_id), do: GenServer.call(__MODULE__, {:get_recents, user_id})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get, user_id, chat_id}, _from, state) do
    session = Map.get(state.sessions, {user_id, chat_id}, %{fsm_state: "idle", data: %{}, book_id: nil})
    {:reply, session, state}
  end

  def handle_call({:get_book, user_id, chat_id}, _from, state) do
    book_id = get_in(state.sessions, [{user_id, chat_id}, :book_id])
    {:reply, book_id, state}
  end

  def handle_call({:get_recents, user_id}, _from, state) do
    recents = Map.get(state.recents, user_id, [])
    {:reply, recents, state}
  end

  @impl true
  def handle_cast({:put, user_id, chat_id, fsm_state, data}, state) do
    key = {user_id, chat_id}
    existing = Map.get(state.sessions, key, %{book_id: nil})
    session = %{fsm_state: fsm_state, data: data, book_id: existing.book_id}
    sessions = Map.put(state.sessions, key, session)
    Process.send_after(self(), {:expire, key}, @idle_ttl_ms)
    {:noreply, %{state | sessions: sessions}}
  end

  def handle_cast({:set_book, user_id, chat_id, book_id}, state) do
    key = {user_id, chat_id}
    existing = Map.get(state.sessions, key, %{fsm_state: "idle", data: %{}})
    sessions = Map.put(state.sessions, key, Map.put(existing, :book_id, book_id))
    {:noreply, %{state | sessions: sessions}}
  end

  def handle_cast({:push_recent, user_id, entry}, state) do
    recents =
      state.recents
      |> Map.get(user_id, [])
      |> then(fn list -> [entry | Enum.reject(list, &(&1 == entry))] end)
      |> Enum.take(@recent_limit)

    {:noreply, %{state | recents: Map.put(state.recents, user_id, recents)}}
  end

  @impl true
  def handle_info({:expire, key}, state) do
    {:noreply, %{state | sessions: Map.delete(state.sessions, key)}}
  end
end
