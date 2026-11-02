defmodule DDD.DataCase do
  @moduledoc """
  Test case for tests that hit Postgres. Each test runs in a sandbox transaction that
  is shared with other processes (the outbox poller), so these tests are not async.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias DDD.TestRepo, as: Repo
    end
  end

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(DDD.TestRepo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
