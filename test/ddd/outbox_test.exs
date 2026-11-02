defmodule DDD.OutboxTest do
  use DDD.DataCase

  import ExUnit.CaptureLog

  alias DDD.Outbox.Poller

  defmodule Ping do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :n, :integer
    end
  end

  # Every test handler delegates here, so a test decides what each handler does.
  # The behaviour is `:ok`, another value to return, or a function of the event.
  def run(name, event) do
    send(:persistent_term.get({__MODULE__, :pid}), {:called, name, event})

    case :persistent_term.get({__MODULE__, name}, :ok) do
      fun when is_function(fun, 1) -> fun.(event)
      other -> other
    end
  end

  defmodule Transactional do
    @moduledoc false
    use DDD.EventHandler, events: [DDD.OutboxTest.Ping]
    @impl DDD.EventHandler
    def handle(event), do: DDD.OutboxTest.run(__MODULE__, event)
  end

  defmodule Second do
    @moduledoc false
    use DDD.EventHandler, events: [DDD.OutboxTest.Ping]
    @impl DDD.EventHandler
    def handle(event), do: DDD.OutboxTest.run(__MODULE__, event)
  end

  defmodule NonTransactional do
    @moduledoc false
    use DDD.EventHandler, events: [DDD.OutboxTest.Ping], transaction: false
    @impl DDD.EventHandler
    def handle(event), do: DDD.OutboxTest.run(__MODULE__, event)
  end

  # Not a DDD.EventHandler at all: any module with handle/1 is accepted.
  defmodule Legacy do
    @moduledoc false
    def handle(event), do: DDD.OutboxTest.run(__MODULE__, event)
  end

  @handlers [Transactional, Second, NonTransactional, Legacy]

  setup do
    :persistent_term.put({__MODULE__, :pid}, self())
    start_poller(backoff_ms: fn _ -> 0 end, max_retries: 2)

    on_exit(fn ->
      for handler <- @handlers do
        :persistent_term.erase({__MODULE__, handler})
        DDD.EventBus.unsubscribe(Ping, handler)
      end
    end)

    :ok
  end

  defp start_poller(opts) do
    stop_supervised(DDD.Outbox.Poller)
    start_supervised!({DDD.Outbox.Poller, [repo: Repo, interval_ms: 600_000] ++ opts})
  end

  defp subscribe(handlers), do: Enum.each(handlers, &DDD.EventBus.subscribe(Ping, &1))
  defp behave(handler, behaviour), do: :persistent_term.put({__MODULE__, handler}, behaviour)

  # A failure of the system: retried. (A plain `{:error, reason}` is a business answer.)
  defp infra(code), do: {:error, DDD.Error.infrastructure(code: code, message: "#{code}")}

  defp deliveries_with_outcome(id) do
    Repo.query!(
      "SELECT handler, outcome, reason FROM event_deliveries WHERE event_id = $1 ORDER BY handler",
      [Ecto.UUID.dump!(id)]
    ).rows
  end

  # Seconds until the event's next retry.
  defp retry_in(id) do
    %{rows: [[seconds]]} =
      Repo.query!(
        "SELECT EXTRACT(EPOCH FROM (next_attempt_at - (now() AT TIME ZONE 'UTC'))) FROM domain_events WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    seconds |> Decimal.to_float() |> Float.round() |> trunc()
  end

  defp poll_until_dead(id, polls) do
    capture_log(fn -> for _ <- 1..polls, do: Poller.poll_now() end)
    state(id)
  end

  defp insert_event(n \\ 1, occurred_at \\ DateTime.utc_now()) do
    id = UUID.uuid4()

    Repo.insert_all("domain_events", [
      %{
        id: Ecto.UUID.dump!(id),
        event_type: "DDD.OutboxTest.Ping",
        aggregate_id: "agg-1",
        aggregate_type: "My.Aggregate",
        payload: %{"n" => n},
        occurred_at: occurred_at,
        inserted_at: DateTime.utc_now()
      }
    ])

    id
  end

  # {attempts, last_error, published?, dead_lettered?}
  defp state(id) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT attempts, last_error, published_at IS NOT NULL, failed_at IS NOT NULL
          FROM domain_events WHERE id = $1
        """,
        [Ecto.UUID.dump!(id)]
      )

    List.to_tuple(row)
  end

  defp deliveries(id) do
    Repo.query!("SELECT handler FROM event_deliveries WHERE event_id = $1 ORDER BY handler", [
      Ecto.UUID.dump!(id)
    ]).rows
    |> List.flatten()
  end

  # A write we can look for to see whether a handler's work was rolled back.
  defp insert_user do
    Repo.query!(
      "INSERT INTO test_users (id, name, email, created_at, updated_at) " <>
        "VALUES (gen_random_uuid(), 'x', 'x@example.com', now(), now())"
    )
  end

  defp count(table), do: Repo.query!("SELECT count(*) FROM #{table}").rows |> hd() |> hd()

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  describe "delivery" do
    test "reaches every subscribed handler, then the event is marked published" do
      subscribe([Transactional, NonTransactional, Legacy])
      id = insert_event(7)

      assert {:ok, 1} = Poller.poll_now()

      for handler <- [Transactional, NonTransactional, Legacy] do
        assert_received {:called, ^handler, %Ping{n: 7, aggregate_id: "agg-1"}}
      end

      assert {1, nil, true, false} = state(id)

      assert deliveries(id) ==
               [
                 "DDD.OutboxTest.Legacy",
                 "DDD.OutboxTest.NonTransactional",
                 "DDD.OutboxTest.Transactional"
               ]

      assert {:ok, 0} = Poller.poll_now()
    end

    test "an event with no subscribed handler is marked published straight away" do
      id = insert_event()
      assert {:ok, 1} = Poller.poll_now()
      assert {1, nil, true, false} = state(id)
      assert deliveries(id) == []
    end

    test "any return value other than {:error, _} counts as success" do
      subscribe([Legacy])
      behave(Legacy, :whatever)
      id = insert_event()

      assert {:ok, 1} = Poller.poll_now()
      assert {1, nil, true, false} = state(id)
    end

    test "the event is rebuilt with its link to the aggregate and a DateTime occurred_at" do
      subscribe([Transactional])
      insert_event(1)
      Poller.poll_now()

      assert_received {:called, Transactional, event}
      assert event.aggregate_type == "My.Aggregate"
      assert %DateTime{} = event.occurred_at
      assert %DateTime{} = event.created_at
      assert String.length(event.event_id) == 36
    end
  end

  describe "failure and retry" do
    test "a failing handler keeps the event pending; handlers that succeeded are not run again" do
      subscribe([Transactional, Second])
      behave(Second, infra(:boom))
      id = insert_event()

      log = capture_log(fn -> assert {:ok, 1} = Poller.poll_now() end)
      assert log =~ "attempt 1/3"

      assert_received {:called, Transactional, _}
      assert_received {:called, Second, _}
      assert {1, last_error, false, false} = state(id)
      assert last_error =~ "boom"
      assert deliveries(id) == ["DDD.OutboxTest.Transactional"]

      # Second recovers. Only Second runs on the retry.
      behave(Second, :ok)
      flush()

      assert {:ok, 1} = Poller.poll_now()
      assert_received {:called, Second, _}
      refute_received {:called, Transactional, _}

      assert {2, nil, true, false} = state(id)
      assert deliveries(id) == ["DDD.OutboxTest.Second", "DDD.OutboxTest.Transactional"]
    end

    test "every handler is attempted even when an earlier one fails" do
      subscribe([Transactional, Second])
      behave(Transactional, infra(:first_fails))
      insert_event()

      capture_log(fn -> Poller.poll_now() end)
      assert_received {:called, Transactional, _}
      assert_received {:called, Second, _}
    end

    test "a transactional handler that fails is rolled back completely" do
      subscribe([Transactional])

      behave(Transactional, fn _ ->
        insert_user()
        infra(:nope)
      end)

      id = insert_event()
      capture_log(fn -> Poller.poll_now() end)

      assert count("test_users") == 0
      assert deliveries(id) == []
      assert {1, _, false, false} = state(id)
    end

    test "an exception counts as a failure and rolls back too" do
      subscribe([Transactional])

      behave(Transactional, fn _ ->
        insert_user()
        raise "kaboom"
      end)

      id = insert_event()
      log = capture_log(fn -> Poller.poll_now() end)

      assert log =~ "raised: kaboom"
      assert count("test_users") == 0
      assert {1, last_error, false, false} = state(id)
      assert last_error =~ "kaboom"
    end

    test "a throw is a failure as well" do
      subscribe([Legacy])
      behave(Legacy, fn _ -> throw(:oops) end)
      id = insert_event()

      capture_log(fn -> Poller.poll_now() end)
      assert {1, last_error, false, false} = state(id)
      assert last_error =~ "oops"
    end

    test "a nested transaction that rolled back, with the handler still returning :ok, is retried" do
      subscribe([Transactional])

      behave(Transactional, fn _ ->
        insert_user()
        Repo.transaction(fn -> Repo.rollback(:inner) end)
        :ok
      end)

      id = insert_event()
      capture_log(fn -> Poller.poll_now() end)

      assert count("test_users") == 0
      assert deliveries(id) == []
      assert {1, last_error, false, false} = state(id)
      assert last_error =~ "transaction_rolled_back"
    end

    test "an event that crashes the delivery itself is that event's failure, not the poller's" do
      defmodule RaisingBus do
        def handlers_for(_event), do: raise("the bus is down")
      end

      id = insert_event()
      start_poller(event_bus: RaisingBus)
      poller = Process.whereis(Poller)

      log = capture_log(fn -> assert {:ok, 1} = Poller.poll_now() end)

      assert log =~ "crashed: the bus is down"
      assert Process.whereis(Poller) == poller
      assert {1, last_error, false, false} = state(id)
      assert last_error =~ "the bus is down"
    end

    test "such an event is dead-lettered once it has used its retries" do
      defmodule AlwaysRaisingBus do
        def handlers_for(_event), do: raise("still down")
      end

      id = insert_event()
      start_poller(event_bus: AlwaysRaisingBus, max_retries: 0)

      capture_log(fn -> Poller.poll_now() end)
      assert {1, _error, false, true} = state(id)
    end

    test "a payload key the event no longer has is dropped, the others are delivered" do
      subscribe([Transactional])
      id = UUID.uuid4()
      removed = "no_such_field_#{System.unique_integer([:positive])}"

      Repo.insert_all("domain_events", [
        %{
          id: Ecto.UUID.dump!(id),
          event_type: "DDD.OutboxTest.Ping",
          aggregate_id: "agg-1",
          aggregate_type: "My.Aggregate",
          payload: %{"n" => 7, removed => "old"},
          occurred_at: DateTime.utc_now(),
          inserted_at: DateTime.utc_now()
        }
      ])

      capture_log(fn -> Poller.poll_now() end)

      assert_received {:called, Transactional, %Ping{n: 7}}
      assert {1, nil, true, false} = state(id)
    end

    test "a non-transactional handler's effects stay, but the event is still retried" do
      subscribe([NonTransactional])

      behave(NonTransactional, fn _ ->
        insert_user()
        infra(:nope)
      end)

      id = insert_event()
      capture_log(fn -> Poller.poll_now() end)

      assert count("test_users") == 1
      assert deliveries(id) == []
      assert {1, _, false, false} = state(id)

      behave(NonTransactional, :ok)
      assert {:ok, 1} = Poller.poll_now()
      assert {2, nil, true, false} = state(id)
      assert deliveries(id) == ["DDD.OutboxTest.NonTransactional"]
    end

    test "after max_retries retries the event is dead-lettered and no longer claimed" do
      subscribe([Transactional])
      behave(Transactional, infra(:always))
      id = insert_event()

      log =
        capture_log(fn ->
          for _ <- 1..3, do: assert({:ok, 1} = Poller.poll_now())
        end)

      assert log =~ "giving up on DDD.OutboxTest.Ping"
      assert {3, last_error, false, true} = state(id)
      assert last_error =~ "always"

      assert {:ok, 0} = Poller.poll_now()
    end

    test "retries wait for the backoff" do
      start_poller(backoff_ms: fn _ -> 60_000 end, max_retries: 2)
      subscribe([Transactional])
      behave(Transactional, infra(:later))
      id = insert_event()

      capture_log(fn -> assert {:ok, 1} = Poller.poll_now() end)
      assert {:ok, 0} = Poller.poll_now()
      assert {1, _, false, false} = state(id)
    end

    test "a handler that already delivered is skipped without being called" do
      subscribe([Transactional])
      id = insert_event()

      Repo.insert_all("event_deliveries", [
        %{
          event_id: Ecto.UUID.dump!(id),
          handler: "DDD.OutboxTest.Transactional",
          delivered_at: DateTime.utc_now()
        }
      ])

      assert {:ok, 1} = Poller.poll_now()
      refute_received {:called, Transactional, _}
      assert {1, nil, true, false} = state(id)
    end

    test "delivering the same event to the same handler twice only runs it once" do
      event = %Ping{n: 1}

      for handler <- [Transactional, NonTransactional] do
        id = insert_event()
        assert :delivered = DDD.EventHandler.deliver(handler, event, id, Repo)
        assert :skipped = DDD.EventHandler.deliver(handler, event, id, Repo)
        assert_received {:called, ^handler, _}
        refute_received {:called, ^handler, _}
      end
    end
  end

  describe "events produced by a handler (chaining)" do
    test "new events are written with the handler's work and delivered on a later poll" do
      subscribe([Transactional])

      behave(Transactional, fn
        %Ping{n: 1} ->
          insert_event(2)
          :ok

        _ ->
          :ok
      end)

      first = insert_event(1)
      assert count("domain_events") == 1

      assert {:ok, 1} = Poller.poll_now()
      assert {1, nil, true, false} = state(first)
      assert count("domain_events") == 2

      flush()
      assert {:ok, 1} = Poller.poll_now()
      assert_received {:called, Transactional, %Ping{n: 2}}
    end

    test "if the handler fails, the events it produced are rolled back with it" do
      subscribe([Transactional])

      behave(Transactional, fn _ ->
        insert_event(2)
        infra(:after_producing)
      end)

      insert_event(1)
      capture_log(fn -> Poller.poll_now() end)

      assert count("domain_events") == 1
    end
  end

  describe "business rejections" do
    test "a business error is recorded as rejected: published, never retried, not a dead letter" do
      subscribe([Transactional])

      behave(
        Transactional,
        {:error, DDD.Error.business(code: :user_not_found, message: "no such user")}
      )

      id = insert_event()

      log = capture_log(fn -> assert {:ok, 1} = Poller.poll_now() end)
      assert log =~ "rejected"
      assert log =~ "user_not_found"

      assert {1, nil, true, false} = state(id)
      assert [[_, "rejected", reason]] = deliveries_with_outcome(id)
      assert reason =~ "user_not_found"

      assert {:ok, 0} = Poller.poll_now()
      assert [] = DDD.Outbox.DeadLetters.list(Repo, all: true)
    end

    test "a plain reason such as :not_found is a business rejection too" do
      subscribe([Legacy])
      behave(Legacy, {:error, :not_found})
      id = insert_event()

      capture_log(fn -> Poller.poll_now() end)
      assert {1, nil, true, false} = state(id)
      assert [[_, "rejected", ":not_found"]] = deliveries_with_outcome(id)
    end

    test "the rejecting handler is rolled back and the other handlers still deliver" do
      subscribe([Transactional, Second])

      behave(Transactional, fn _ ->
        insert_user()
        {:error, :nope}
      end)

      id = insert_event()
      capture_log(fn -> Poller.poll_now() end)

      assert count("test_users") == 0
      assert_received {:called, Second, _}

      assert [
               ["DDD.OutboxTest.Second", "delivered", nil],
               ["DDD.OutboxTest.Transactional", "rejected", ":nope"]
             ] = deliveries_with_outcome(id)

      assert {1, nil, true, false} = state(id)
    end

    test "a non-transactional handler keeps its effects but the rejection is still recorded" do
      subscribe([NonTransactional])

      behave(NonTransactional, fn _ ->
        insert_user()
        {:error, :nope}
      end)

      id = insert_event()
      capture_log(fn -> Poller.poll_now() end)

      assert count("test_users") == 1
      assert [[_, "rejected", ":nope"]] = deliveries_with_outcome(id)
      assert {1, nil, true, false} = state(id)
    end

    test "a rejection is remembered: the handler is skipped if the event comes round again" do
      subscribe([Transactional])
      behave(Transactional, {:error, :nope})
      id = insert_event()
      capture_log(fn -> Poller.poll_now() end)
      assert_received {:called, Transactional, _}

      Repo.query!("UPDATE domain_events SET published_at = NULL WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

      assert {:ok, 1} = Poller.poll_now()
      refute_received {:called, Transactional, _}
      assert {2, nil, true, false} = state(id)
    end
  end

  describe "retry configuration" do
    setup do
      on_exit(fn -> Application.delete_env(:vicander, :outbox) end)
    end

    setup do
      subscribe([Transactional])
      behave(Transactional, infra(:down))
      %{id: insert_event()}
    end

    test "by default an event is retried 10 times: 11 attempts, then it is dead-lettered", %{
      id: id
    } do
      start_poller(backoff_ms: fn _ -> 0 end)

      assert {10, _, false, false} = poll_until_dead(id, 10)
      assert {11, _, false, true} = poll_until_dead(id, 1)
    end

    test "max_retries comes from application config", %{id: id} do
      Application.put_env(:vicander, :outbox, max_retries: 1)
      start_poller(backoff_ms: fn _ -> 0 end)

      assert {2, _, false, true} = poll_until_dead(id, 5)
    end

    test "a poller option wins over application config", %{id: id} do
      Application.put_env(:vicander, :outbox, max_retries: 0)
      start_poller(backoff_ms: fn _ -> 0 end, max_retries: 2)

      assert {3, _, false, true} = poll_until_dead(id, 5)
    end

    test "max_retries: 0 means a single attempt", %{id: id} do
      start_poller(backoff_ms: fn _ -> 0 end, max_retries: 0)
      assert {1, _, false, true} = poll_until_dead(id, 3)
    end

    test "the backoff base comes from application config", %{id: id} do
      Application.put_env(:vicander, :outbox, backoff_base_ms: 60_000)
      start_poller([])

      capture_log(fn -> Poller.poll_now() end)
      assert retry_in(id) == 60
    end

    test "the default backoff doubles and is capped", %{id: id} do
      Application.put_env(:vicander, :outbox, backoff_base_ms: 1_000, backoff_max_ms: 4_000)
      start_poller([])

      delays =
        for _ <- 1..4 do
          capture_log(fn -> Poller.poll_now() end)
          delay = retry_in(id)
          Repo.query!("UPDATE domain_events SET next_attempt_at = NULL")
          delay
        end

      assert delays == [1, 2, 4, 4]
    end
  end

  describe "claiming" do
    test "a claimed event is leased and not claimed again until the lease expires" do
      insert_event()

      assert [%{event_type: "DDD.OutboxTest.Ping", attempts: 1}] = Poller.claim(Repo, 10, 60_000)
      assert [] = Poller.claim(Repo, 10, 60_000)

      # Simulate a poller that died mid-delivery: its lease runs out and the event is reclaimed.
      Repo.query!(
        "UPDATE domain_events SET locked_until = (now() AT TIME ZONE 'UTC') - interval '1 second'"
      )

      assert [_] = Poller.claim(Repo, 10, 60_000)
    end

    test "the attempt is counted at claim time, so a crash mid-delivery still uses one up" do
      id = insert_event()

      # Claimed, and then the VM dies before anything is recorded.
      assert [%{attempts: 1}] = Poller.claim(Repo, 10, 60_000)

      Repo.query!(
        "UPDATE domain_events SET locked_until = (now() AT TIME ZONE 'UTC') - interval '1 second'"
      )

      assert [%{attempts: 2}] = Poller.claim(Repo, 10, 60_000)
      assert {2, nil, false, false} = state(id)
    end

    test "claims the oldest events first, up to the batch size" do
      base = DateTime.utc_now()
      third = insert_event(3, DateTime.add(base, 2, :second))
      first = insert_event(1, base)
      second = insert_event(2, DateTime.add(base, 1, :second))

      claimed = Poller.claim(Repo, 2, 60_000)
      assert Enum.map(claimed, & &1.payload["n"]) == [1, 2]
      assert Enum.map(claimed, & &1.id) == [first, second]
      assert [%{payload: %{"n" => 3}}] = Poller.claim(Repo, 2, 60_000)
      assert third
    end

    test "published and dead-lettered events are never claimed" do
      published = insert_event(1)
      dead = insert_event(2)

      Repo.query!(
        "UPDATE domain_events SET published_at = (now() AT TIME ZONE 'UTC') WHERE id = $1",
        [
          Ecto.UUID.dump!(published)
        ]
      )

      Repo.query!(
        "UPDATE domain_events SET failed_at = (now() AT TIME ZONE 'UTC') WHERE id = $1",
        [
          Ecto.UUID.dump!(dead)
        ]
      )

      assert [] = Poller.claim(Repo, 10, 60_000)
    end
  end

  describe "DDD.EventHandler" do
    test "exposes its events and transaction settings" do
      assert Transactional.__handler_events__() == [Ping]
      assert Transactional.__handler_repo__() == DDD.TestRepo
      assert NonTransactional.__handler_repo__() == nil
    end

    test "subscribe/0 and unsubscribe/0 manage the event bus subscription" do
      on_exit(fn -> Transactional.unsubscribe() end)

      Transactional.subscribe()
      Transactional.subscribe()
      assert DDD.EventBus.handlers_for(Ping) == [Transactional]

      Second.subscribe()
      assert DDD.EventBus.handlers_for(Ping) == [Transactional, Second]

      Transactional.unsubscribe()
      Second.unsubscribe()
      assert DDD.EventBus.handlers_for(Ping) == []
    end
  end
end
