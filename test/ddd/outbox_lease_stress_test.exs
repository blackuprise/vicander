defmodule DDD.OutboxLeaseStressTest do
  @moduledoc """
  What renewing the lease of a batch does, with real commits and a database clock that moves.

  The Sandbox runs a test in one transaction, and Postgres' `now()` stands still inside it, so a
  lease can never run out there. This test switches the pool to `:auto`, like
  `DDD.TransactionStressTest`, and checks two things:

    * **Correctness.** While a slow handler works through a batch, a second "node" that claims
      events as soon as their lease allows never gets an event whose handler has not finished
      (it would run that handler a second time). Without the renewal it does, as soon as the
      first lease runs out.
    * **Cost.** With fast handlers the renewal must cost no query at all; with a lease so short
      that every event renews, the report shows what one renewal costs.

  Timings are machine dependent, so they are printed, not asserted. It is excluded from the
  normal run; run it with

      mix test --only stress test/ddd/outbox_lease_stress_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag :capture_log
  @moduletag timeout: 120_000

  alias DDD.Outbox.Poller
  alias DDD.TestRepo, as: Repo
  alias Ecto.Adapters.SQL.Sandbox

  @handled :outbox_lease_handled

  defmodule Ping do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :n, :integer
    end
  end

  defmodule Recorder do
    @moduledoc false
    # Not transactional: the point is a handler that a second delivery would run again.
    use DDD.EventHandler, events: [DDD.OutboxLeaseStressTest.Ping], transaction: false

    @impl DDD.EventHandler
    def handle(event) do
      sleep = :persistent_term.get({DDD.OutboxLeaseStressTest, :sleep_ms}, 0)
      if sleep > 0, do: Process.sleep(sleep)
      :ets.insert(:outbox_lease_handled, {event.event_id})
      :ok
    end
  end

  setup do
    Sandbox.mode(Repo, :auto)
    Repo.query!("DELETE FROM domain_events")

    :ets.new(@handled, [:public, :named_table, :bag])
    :persistent_term.put({__MODULE__, :sleep_ms}, 0)
    DDD.EventBus.subscribe(Ping, Recorder)
    stop_supervised(Poller)

    queries = :ets.new(:outbox_lease_queries, [:public, :duplicate_bag])

    :telemetry.attach(
      "outbox-lease-stress",
      [:ddd, :test_repo, :query],
      &__MODULE__.record/4,
      queries
    )

    on_exit(fn ->
      :telemetry.detach("outbox-lease-stress")
      DDD.EventBus.unsubscribe(Ping, Recorder)
      :persistent_term.erase({__MODULE__, :sleep_ms})
      Repo.query!("DELETE FROM domain_events")
      Sandbox.mode(Repo, :manual)
    end)

    %{queries: queries}
  end

  @doc false
  def record(_event, measurements, %{query: query}, queries) do
    :ets.insert(queries, {query, measurements[:total_time] || 0})
  rescue
    # The table dies with the test process; the poller can still run a query a moment later.
    ArgumentError -> :ok
  end

  defp start_poller(opts) do
    start_supervised!(
      {Poller,
       [repo: Repo, interval_ms: 600_000, backoff_ms: fn _ -> 0 end, batch_size: 1_000] ++ opts}
    )
  end

  defp insert_events(aggregate, ns) do
    now = DateTime.utc_now()

    rows =
      for n <- ns do
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          event_type: "DDD.OutboxLeaseStressTest.Ping",
          aggregate_id: aggregate,
          aggregate_type: "Lease.Aggregate",
          payload: %{"n" => n},
          occurred_at: DateTime.add(now, n, :millisecond),
          inserted_at: now
        }
      end

    Repo.insert_all("domain_events", rows)
  end

  defp scalar(sql), do: Repo.query!(sql).rows |> hd() |> hd()
  defp published, do: scalar("SELECT count(*) FROM domain_events WHERE published_at IS NOT NULL")

  # `UPDATE domain_events SET locked_until = $1 WHERE …` is a renewal; the claim also sets
  # `attempts`, and marking published sets `published_at`.
  defp renewals(queries) do
    queries
    |> :ets.tab2list()
    |> Enum.filter(fn {sql, _} -> sql =~ ~s(SET "locked_until" = $1 WHERE) end)
  end

  defp ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  test "a second node never claims an event whose handler is still running" do
    # 4 events of one aggregate, 400 ms per handler, a lease of 600 ms: the batch takes 1.6 s,
    # nearly three leases. Another node polls every 50 ms the whole time.
    :persistent_term.put({__MODULE__, :sleep_ms}, 400)
    start_poller(lease_ms: 600, concurrency: 1)
    insert_events("a", 1..4)

    poller = Process.whereis(Poller)
    task = Task.async(fn -> GenServer.call(poller, :poll_now, 30_000) end)

    {stolen, result} = steal_until_done(task, [])

    assert {:ok, 4} = result

    # Events the first node had finished may lapse and be claimed again: their handlers
    # already ran, so that is a no-op. Anything else is a second run of a running handler.
    running_when_claimed = Enum.reject(stolen, fn {_id, handled_before?} -> handled_before? end)

    assert running_when_claimed == [],
           "claimed while their handler was running: #{inspect(running_when_claimed)}"

    assert published() == 4

    assert :ets.tab2list(@handled) |> Enum.frequencies_by(&elem(&1, 0)) |> Map.values() == [
             1,
             1,
             1,
             1
           ]

    IO.puts(
      "\n── lease renewal under a slow handler\n" <>
        "  4 events × 400 ms, lease 600 ms; events claimed by another node meanwhile: #{length(stolen)} " <>
        "(all of them already delivered)"
    )
  end

  # Claim like another node would, as often as the lease allows, until the poll is over.
  defp steal_until_done(task, acc) do
    case Task.yield(task, 50) do
      nil ->
        rows = Poller.claim(Repo, 10, 600)
        seen = for row <- rows, do: {row.id, :ets.member(@handled, row.id)}
        steal_until_done(task, acc ++ seen)

      {:ok, result} ->
        {acc, result}
    end
  end

  test "fast handlers cost no lease renewal; a lease too short to hold costs one per event",
       %{queries: queries} do
    events = 300

    # 30 aggregates of 10 events, 4 delivered at a time, default 30 s lease.
    start_poller(lease_ms: 30_000, concurrency: 4)
    for a <- 1..30, do: insert_events("agg-#{a}", 1..10)

    {micros, {:ok, ^events}} = :timer.tc(fn -> Poller.poll_now() end)
    default = %{wall_ms: micros / 1000, renewals: renewals(queries)}

    assert published() == events
    assert default.renewals == []

    # The same load with a 2 ms lease: more than half of it is gone before every event.
    :ets.delete_all_objects(queries)
    :ets.delete_all_objects(@handled)
    Repo.query!("DELETE FROM domain_events")
    stop_supervised(Poller)
    start_poller(lease_ms: 2, concurrency: 4)
    for a <- 1..30, do: insert_events("agg-#{a}", 1..10)

    {micros, {:ok, ^events}} = :timer.tc(fn -> Poller.poll_now() end)
    short = %{wall_ms: micros / 1000, renewals: renewals(queries)}

    assert published() == events
    assert short.renewals != []
    # A renewal never causes a second run of a handler.
    assert :ets.tab2list(@handled)
           |> Enum.frequencies_by(&elem(&1, 0))
           |> Map.values()
           |> Enum.uniq() == [1]

    per_renewal = Enum.sum(for {_, t} <- short.renewals, do: ms(t)) / length(short.renewals)

    IO.puts("""

    ── lease renewal cost (#{events} events, 30 aggregates, concurrency 4)
      lease 30 s : #{round(default.wall_ms)} ms wall · #{length(default.renewals)} renewal queries
      lease 2 ms : #{round(short.wall_ms)} ms wall · #{length(short.renewals)} renewal queries (one per event, the worst case)
      one renewal: #{Float.round(per_renewal, 2)} ms of database time
    """)
  end
end
