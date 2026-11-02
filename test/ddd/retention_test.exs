defmodule DDD.RetentionTest do
  use DDD.DataCase

  alias DDD.Outbox.{Pruner, Retention}

  defp insert_event(attrs) do
    id = UUID.uuid4()
    days_old = Keyword.get(attrs, :days_old, 40)
    at = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days_old * 86_400, :second)

    row =
      Map.merge(
        %{
          id: Ecto.UUID.dump!(id),
          event_type: "DDD.RetentionTest.Ping",
          aggregate_id: "a",
          aggregate_type: "A",
          payload: %{},
          occurred_at: at,
          inserted_at: at,
          published_at: nil
        },
        Map.new(attrs, fn
          {:published, true} -> {:published_at, at}
          {:resolved, true} -> {:resolved_at, at}
          {:dead, true} -> {:failed_at, at}
          other -> other
        end)
        |> Map.drop([:days_old, :published, :resolved, :dead])
      )

    Repo.insert_all("domain_events", [row])
    id
  end

  defp exists?(id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM domain_events WHERE id = $1", [Ecto.UUID.dump!(id)])

    n == 1
  end

  test "old published events are deleted, with their delivery records" do
    old =
      insert_event(
        published_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400),
        days_old: 40
      )

    Repo.insert_all("event_deliveries", [
      %{event_id: Ecto.UUID.dump!(old), handler: "H", delivered_at: DateTime.utc_now()}
    ])

    assert {:ok, %{deleted: 1}} = Retention.prune(Repo, older_than_days: 30)
    refute exists?(old)
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM event_deliveries")
  end

  test "recent events, waiting events, retried events and unresolved dead letters stay" do
    recent_published = insert_event(published_at: NaiveDateTime.utc_now(), days_old: 1)
    waiting = insert_event(days_old: 90)
    retried = insert_event(days_old: 90, attempts: 3, next_attempt_at: NaiveDateTime.utc_now())
    dead = insert_event(days_old: 90, dead: true)

    assert {:ok, %{deleted: 0}} = Retention.prune(Repo, older_than_days: 30)
    assert Enum.all?([recent_published, waiting, retried, dead], &exists?/1)
  end

  test "resolved dead letters are deleted once old enough" do
    resolved = insert_event(days_old: 90, dead: true, resolved: true)
    unresolved = insert_event(days_old: 90, dead: true)

    assert {:ok, %{deleted: 1}} = Retention.prune(Repo, older_than_days: 30)
    refute exists?(resolved)
    assert exists?(unresolved)
  end

  test "a big backlog is deleted in batches" do
    for _ <- 1..7 do
      insert_event(published_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400))
    end

    assert {:ok, %{deleted: 7}} = Retention.prune(Repo, older_than_days: 30, batch: 3)
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM domain_events")
  end

  test "the age is required and must be positive: deleting is never a default" do
    assert_raise KeyError, fn -> Retention.prune(Repo, []) end

    assert_raise ArgumentError, ~r/positive integer/, fn ->
      Retention.prune(Repo, older_than_days: 0)
    end

    assert_raise ArgumentError, ~r/positive integer/, fn ->
      Retention.prune(Repo, older_than_days: "30")
    end
  end

  describe "the pruner" do
    test "prunes on demand and on its timer" do
      insert_event(published_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400))

      start_supervised!({Pruner, repo: Repo, older_than_days: 30, every_ms: 600_000})
      assert {:ok, %{deleted: 1}} = Pruner.prune_now()
      assert {:ok, %{deleted: 0}} = Pruner.prune_now()

      insert_event(published_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400))
      send(Pruner, :prune)
      send(Pruner, :ignored)
      assert {:ok, %{deleted: 0}} = Pruner.prune_now()
      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM domain_events")
    end

    test "the supervisor starts it when asked" do
      stop_supervised(DDD.EventBus)
      :ok = Supervisor.terminate_child(DDD.TestSupervisor, DDD.EventBus)
      on_exit(fn -> Supervisor.restart_child(DDD.TestSupervisor, DDD.EventBus) end)

      start_supervised!(
        {DDD.Supervisor, poller: false, retention: [older_than_days: 30, every_ms: 600_000]}
      )

      assert is_pid(Process.whereis(Pruner))
    end
  end
end
