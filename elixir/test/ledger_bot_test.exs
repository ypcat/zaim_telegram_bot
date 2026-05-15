defmodule LedgerBotTest do
  use ExUnit.Case
  doctest LedgerBot

  test "greets the world" do
    assert LedgerBot.hello() == :world
  end
end
