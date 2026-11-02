defmodule DDD.SupervisorTest do
  # Not async: it starts processes with global names (the event bus, the poller).
  use DDD.DataCase

  defmodule Ping do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :n, :integer
    end
  end

  defmodule Handler do
    @moduledoc false
    use DDD.EventHandler, events: [DDD.SupervisorTest.Ping]

    @impl DDD.EventHandler
    def handle(_event), do: :ok
  end

  setup do
    # The test helper already runs an event bus (and these tests start a second supervisor).
    stop_supervised(DDD.EventBus)
    :ok = Supervisor.terminate_child(DDD.TestSupervisor, DDD.EventBus)

    on_exit(fn ->
      # Hand the bus back to the test supervisor for the tests that follow.
      Supervisor.restart_child(DDD.TestSupervisor, DDD.EventBus)
    end)
  end

  defp children(supervisor),
    do: supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

  test "starts the bus, subscribes the handlers, then the poller and the dead-letter handler" do
    pid = start_supervised!({DDD.Supervisor, handlers: [Handler]})

    assert DDD.EventBus.handlers_for(Ping) == [Handler]
    assert is_pid(Process.whereis(DDD.Outbox.Poller))
    assert is_pid(Process.whereis(DDD.Outbox.DeadLetterHandler))

    assert Enum.sort(children(pid), :desc) |> length() == 4
  end

  test "poller: false starts no poller and no dead-letter handler" do
    pid = start_supervised!({DDD.Supervisor, handlers: [Handler], poller: false})

    assert DDD.EventBus.handlers_for(Ping) == [Handler]
    assert Process.whereis(DDD.Outbox.Poller) == nil
    assert Process.whereis(DDD.Outbox.DeadLetterHandler) == nil
    assert length(children(pid)) == 2
  end

  test "poller options reach the poller, and the repo can be named" do
    start_supervised!(
      {DDD.Supervisor, poller: [interval_ms: 600_000, batch_size: 7], repo: DDD.TestRepo}
    )

    state = :sys.get_state(DDD.Outbox.Poller)
    assert state.batch_size == 7
    assert state.interval_ms == 600_000
    assert state.repo == DDD.TestRepo
  end

  test "the repo defaults to the configured one" do
    start_supervised!({DDD.Supervisor, poller: [interval_ms: 600_000]})
    assert :sys.get_state(DDD.Outbox.Poller).repo == DDD.TestRepo
  end

  test "no handlers is fine, and the supervisor can be named" do
    start_supervised!({DDD.Supervisor, name: :my_ddd, poller: false})
    assert DDD.EventBus.handlers_for(Ping) == []
    assert Process.whereis(:my_ddd) |> is_pid()
  end

  test "when the event bus restarts, the subscriptions come back" do
    start_supervised!({DDD.Supervisor, handlers: [Handler], poller: false})
    bus = Process.whereis(DDD.EventBus)
    ref = Process.monitor(bus)
    Process.exit(bus, :kill)
    assert_receive {:DOWN, ^ref, :process, ^bus, :killed}

    # Restarted, and subscribed again before anything else can publish.
    wait_until(fn ->
      is_pid(Process.whereis(DDD.EventBus)) and Process.whereis(DDD.EventBus) != bus
    end)

    wait_until(fn -> DDD.EventBus.handlers_for(Ping) == [Handler] end)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
