defmodule DDD.TransactionStressTest do
  @moduledoc """
  Integration test of the transaction paths under real concurrency.

  Every other database test runs inside the Sandbox's one big transaction, which hides what
  real transactions do: commits, row locks, lost races, pool queueing. This test switches the
  pool to `:auto` so every process gets its own connection and everything is really committed,
  then drives the command → repository → outbox → poller → handler chain from many processes.

  It asserts only on correctness (no lost update, no event lost or delivered twice, no row
  claimed by two pollers). Timings and query counts are machine dependent, so they are printed,
  not asserted. It is excluded from the normal run; run it with

      mix test --only stress

  and read the report it prints (`STRESS_SCALE=4` multiplies the load).
  """
  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag :capture_log
  @moduletag timeout: 120_000

  alias DDD.Outbox.Poller
  alias DDD.TestRepo, as: Repo
  alias Ecto.Adapters.SQL.Sandbox

  @scale String.to_integer(System.get_env("STRESS_SCALE", "1"))

  defmodule Bumped do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :n, :integer
    end
  end

  defmodule Counter do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :n, :integer, required: true
    end

    defop bump(counter) do
      counter |> Map.put(:n, counter.n + 1) |> emit_event(Bumped.new(%{n: counter.n + 1}))
    end
  end

  defmodule CounterPort do
    @moduledoc false
    use DDD.Repository

    repo Counter do
    end
  end

  defmodule Counters do
    @moduledoc false
    use DDD.Repository.Ecto, port: CounterPort, repo: DDD.TestRepo, table: "stress_counters"
  end

  defmodule Bump do
    @moduledoc false
    use DDD.Command, retry_on_conflict: 100

    command do
      field :id, :string, required: true
    end

    @impl DDD.Command
    def execute(%{id: id}) do
      with {:ok, counter} <- Counters.find_by_id(id),
           {:ok, counter} <- Counter.bump(counter),
           do: Counters.save(counter)
    end
  end

  # One command that changes many aggregates: the case a unit of work is for.
  defmodule BumpMany do
    @moduledoc false
    use DDD.Command

    command do
      field :ids, {:array, :string}, required: true, loads: Counters
    end

    @impl DDD.Command
    def execute(%{ids: ids}) do
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, saved} ->
        with {:ok, counter} <- Counters.find_by_id(id),
             {:ok, counter} <- Counter.bump(counter),
             {:ok, counter} <- Counters.save(counter) do
          {:cont, {:ok, [counter | saved]}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  # Takes the lock of one row, waits, and asks for the lock of another: two of these, in opposite
  # order, deadlock.
  defmodule CrossLock do
    @moduledoc false
    use DDD.Command, retry_on_conflict: 5

    command do
      field :first, :string, required: true
      field :second, :string, required: true
    end

    @impl DDD.Command
    def execute(%{first: first, second: second}) do
      lock(first)
      Process.sleep(300)
      lock(second)
      {:ok, :locked}
    end

    defp lock(id) do
      DDD.TestRepo.query!("SELECT id FROM stress_counters WHERE id = $1 FOR UPDATE", [
        Ecto.UUID.dump!(id)
      ])
    end
  end

  # A transactional handler that does a write of its own, as a real projection would. The
  # write is part of the delivery transaction, so it is rolled back if the delivery is.
  defmodule Handler do
    @moduledoc false
    use DDD.EventHandler, events: [DDD.TransactionStressTest.Bumped]

    @impl DDD.EventHandler
    def handle(event) do
      DDD.TestRepo.query!("INSERT INTO stress_handled (event_id) VALUES ($1)", [
        Ecto.UUID.dump!(event.event_id)
      ])

      :ok
    end
  end

  setup do
    # Real connections and real commits: nothing below is rolled back by the Sandbox.
    Sandbox.mode(Repo, :auto)

    Repo.query!("DELETE FROM domain_events")
    Repo.query!("DROP TABLE IF EXISTS stress_counters, stress_handled")

    Repo.query!("""
    CREATE TABLE stress_counters (
      id uuid PRIMARY KEY, n integer,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    Repo.query!("CREATE TABLE stress_handled (event_id uuid NOT NULL)")

    ets = :ets.new(:stress_queries, [:public, :duplicate_bag])
    retries = :counters.new(1, [])

    :telemetry.attach_many(
      "stress-test",
      [[:ddd, :test_repo, :query], [:ddd, :command, :retry]],
      &__MODULE__.record/4,
      %{ets: ets, retries: retries}
    )

    DDD.EventBus.subscribe(Bumped, Handler)
    {:ok, _} = Application.ensure_all_started(:telemetry)

    stop_supervised(DDD.Outbox.Poller)

    start_supervised!(
      {DDD.Outbox.Poller,
       repo: Repo, interval_ms: 600_000, batch_size: 100, backoff_ms: fn _ -> 0 end}
    )

    on_exit(fn ->
      :telemetry.detach("stress-test")
      DDD.EventBus.unsubscribe(Bumped, Handler)
      Repo.query!("DELETE FROM domain_events")
      Repo.query!("DROP TABLE IF EXISTS stress_counters, stress_handled")
      Sandbox.mode(Repo, :manual)
    end)

    %{ets: ets, retries: retries}
  end

  @doc false
  def record([:ddd, :test_repo, :query], m, meta, %{ets: ets}) do
    # The table dies with the test process; the poller can still run a query a moment later.
    insert_query(ets, {
      meta.query,
      ms(m.total_time),
      ms(Map.get(m, :queue_time, 0)),
      ms(Map.get(m, :query_time, 0))
    })
  end

  def record([:ddd, :command, :retry], _m, _meta, %{retries: retries}),
    do: :counters.add(retries, 1, 1)

  defp insert_query(ets, row) do
    :ets.insert(ets, row)
  rescue
    ArgumentError -> :ok
  end

  defp ms(nil), do: 0.0
  defp ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  # Run `fun`, return {result, report} where the report has the wall time and what the database
  # was asked for meanwhile.
  defp measure(ctx, fun) do
    :ets.delete_all_objects(ctx.ets)
    :counters.put(ctx.retries, 1, 0)
    {micros, result} = :timer.tc(fun)
    rows = :ets.tab2list(ctx.ets)

    report = %{
      wall_ms: micros / 1000,
      queries: length(rows),
      db_ms: rows |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      queue_ms: rows |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
      retries: :counters.get(ctx.retries, 1),
      statements:
        rows |> Enum.frequencies_by(&normalize(elem(&1, 0))) |> Enum.sort_by(&(-elem(&1, 1)))
    }

    {result, report}
  end

  defp normalize(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.slice(0, 90)

  defp print(title, report, extra \\ []) do
    lines =
      [
        "wall #{round(report.wall_ms)} ms · #{report.queries} queries · " <>
          "db time #{round(report.db_ms)} ms · waiting for a pool connection #{round(report.queue_ms)} ms · " <>
          "command retries #{report.retries}"
      ] ++
        extra ++
        Enum.map(report.statements, fn {sql, n} ->
          "  #{String.pad_leading("#{n}", 5)}×  #{sql}"
        end)

    IO.puts("\n── #{title}\n" <> Enum.join(lines, "\n"))
  end

  defp new_counter do
    {:ok, counter} = Counter.new(n: 0)
    {:ok, counter} = Counters.save(counter)
    counter
  end

  defp count(sql), do: Repo.query!(sql).rows |> hd() |> hd()

  defp concurrently(items, concurrency, fun) do
    items
    |> Task.async_stream(fun, max_concurrency: concurrency, timeout: 60_000, ordered: false)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # ───────────────────────────────────────────────────────────────────────────

  test "what one save and one delivery cost, query by query", ctx do
    {counter, save_new} = measure(ctx, fn -> new_counter() end)
    print("save of a NEW aggregate (no events)", save_new)

    {:ok, bumped} = Counter.bump(counter)
    {{:ok, _}, save_existing} = measure(ctx, fn -> Counters.save(bumped) end)
    print("save of an EXISTING aggregate with 1 event", save_existing)

    {:ok, _} =
      measure(ctx, fn -> Bump.call(%{id: counter.id}) end)
      |> then(fn {r, rep} ->
        print("whole command (find + bump + save, in its own transaction)", rep)
        r
      end)

    {1, poll} = measure(ctx, fn -> poll_all() end) |> then(fn {_n, rep} -> {1, rep} end)

    print(
      "delivering 2 events to 1 transactional handler (claim + deliver + mark published)",
      poll
    )

    assert count("SELECT count(*) FROM domain_events WHERE published_at IS NOT NULL") == 2
    assert count("SELECT count(*) FROM stress_handled") == 2
  end

  test "20 processes fight over ONE aggregate: no lost update, no lost event", ctx do
    counter = new_counter()
    workers = 20 * @scale
    per_worker = 5

    {results, report} =
      measure(ctx, fn ->
        concurrently(1..workers, workers, fn _ ->
          for _ <- 1..per_worker, do: Bump.call(%{id: counter.id})
        end)
        |> List.flatten()
      end)

    ok = Enum.count(results, &match?({:ok, _}, &1))
    failed = results -- Enum.filter(results, &match?({:ok, _}, &1))

    print(
      "contention on one row (#{workers} workers × #{per_worker} commands, pool size 10)",
      report,
      [
        "succeeded #{ok}/#{length(results)}, gave up after 100 retries: #{length(failed)}",
        "wasted work: #{report.retries} command re-runs = #{Float.round(report.retries / max(ok, 1), 2)} per success"
      ]
    )

    # The invariant that matters: every success is in the row AND in the outbox, exactly once.
    assert [[n, version]] = Repo.query!("SELECT n, version FROM stress_counters").rows
    assert n == ok
    assert version == ok + 1
    assert count("SELECT count(*) FROM domain_events") == ok
    assert count("SELECT count(DISTINCT payload->>'n') FROM domain_events") == ok
  end

  test "one command that changes 20 aggregates: the cost per aggregate", ctx do
    ids = for _ <- 1..20, do: new_counter().id
    runs = 10 * @scale

    {results, report} =
      measure(ctx, fn -> for _ <- 1..runs, do: BumpMany.call(%{ids: ids}) end)

    print("#{runs} runs of ONE command bumping #{length(ids)} aggregates", report, [
      "per command: #{round(report.wall_ms / runs)} ms, #{div(report.queries, runs)} queries " <>
        "(#{Float.round(report.queries / runs / length(ids), 2)} per aggregate)"
    ])

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Repo.query!("SELECT DISTINCT n FROM stress_counters").rows == [[runs]]
    assert count("SELECT count(*) FROM domain_events") == runs * length(ids)
  end

  test "a real deadlock is reported as :deadlock_detected and the command runs again", ctx do
    a = new_counter().id
    b = new_counter().id

    {results, report} =
      measure(ctx, fn ->
        concurrently([{a, b}, {b, a}], 2, fn {first, second} ->
          CrossLock.call(%{first: first, second: second})
        end)
      end)

    print("two commands that lock two rows in opposite order", report, [
      "both succeeded: #{inspect(results)}"
    ])

    # Postgres aborted one of them (after its deadlock_timeout); it was run again and finished.
    assert results == [{:ok, :locked}, {:ok, :locked}]
    assert report.retries >= 1
  end

  test "200 independent aggregates saved in parallel: throughput without contention", ctx do
    total = 200 * @scale

    {ids, report} =
      measure(ctx, fn ->
        concurrently(1..total, 8, fn _ ->
          counter = new_counter()
          {:ok, _} = Bump.call(%{id: counter.id})
          counter.id
        end)
      end)

    print("#{total} × (create + bump) over 8 workers", report, [
      "#{Float.round(total / (report.wall_ms / 1000), 1)} commands/s, " <>
        "#{Float.round(report.queries / total, 1)} queries per create+bump"
    ])

    assert length(Enum.uniq(ids)) == total
    assert count("SELECT count(*) FROM domain_events") == total
  end

  test "the outbox drains every event once, however it is claimed", ctx do
    total = 300 * @scale
    seed_events(total)

    {_, report} = measure(ctx, fn -> poll_all() end)

    print("draining #{total} events through ONE poller (concurrency 4, batch 100)", report, [
      "#{Float.round(total / (report.wall_ms / 1000), 1)} events/s, " <>
        "#{Float.round(report.wall_ms / total, 2)} ms and #{Float.round(report.queries / total, 1)} queries per event"
    ])

    assert count("SELECT count(*) FROM domain_events WHERE published_at IS NOT NULL") == total
    # Exactly one delivery record and one handler side effect per event.
    assert count("SELECT count(*) FROM event_deliveries") == total
    assert count("SELECT count(*) FROM stress_handled") == total
    assert count("SELECT count(DISTINCT event_id) FROM stress_handled") == total
  end

  test "pollers on several nodes never claim the same event (SKIP LOCKED)", ctx do
    total = 400 * @scale
    seed_events(total)

    {claims, report} =
      measure(ctx, fn ->
        concurrently(1..4, 4, fn _ -> claim_until_empty() end)
      end)

    ids = claims |> List.flatten() |> Enum.map(& &1.id)
    print("4 concurrent claimers, batch 50, #{total} events", report)

    assert length(ids) == total, "every event is claimed"
    assert length(Enum.uniq(ids)) == total, "no event is claimed twice"
  end

  test "a backlog drains at the speed of the handlers, not of the poll interval", _ctx do
    # The real, running poller (not `poll_now`) with the production interval of 3 s and a small
    # batch of 20. It used to wait the interval after EVERY batch (20 / 3 s = ~7 events/s here);
    # now it polls again at once while batches come back full.
    total = 300 * @scale

    for concurrency <- [1, 4] do
      stop_supervised(DDD.Outbox.Poller)

      start_supervised!(
        {DDD.Outbox.Poller,
         repo: Repo, interval_ms: 3_000, batch_size: 20, concurrency: concurrency}
      )

      before = count("SELECT count(*) FROM domain_events WHERE published_at IS NOT NULL")
      seed_events(total)

      {micros, :ok} =
        :timer.tc(fn ->
          # Kick the first cycle instead of waiting out the idle sleep of the fresh poller.
          send(Process.whereis(DDD.Outbox.Poller), :poll)
          wait_until(fn -> published() >= before + total end)
        end)

      IO.puts(
        "\n── #{total} events, interval 3000 ms, batch 20, concurrency #{concurrency}: " <>
          "#{round(micros / 1000)} ms = #{Float.round(total / (micros / 1_000_000), 1)} events/s"
      )

      assert published() == before + total
      # 15 batches that each slept the 3 s interval would take 45 s.
      assert micros / 1_000_000 < 10, "drained without sleeping the interval between batches"
    end
  end

  defp published, do: count("SELECT count(*) FROM domain_events WHERE published_at IS NOT NULL")

  defp wait_until(fun, tries \\ 600) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Poll until a cycle claims nothing.
  defp poll_all do
    case Poller.poll_now() do
      {:ok, 0} -> :ok
      {:ok, _} -> poll_all()
    end
  end

  defp claim_until_empty do
    case Poller.claim(Repo, 50, 30_000) do
      [] -> []
      rows -> rows ++ claim_until_empty()
    end
  end

  # `total` unpublished Bumped events, written the way the repository writes them.
  defp seed_events(total) do
    now = DateTime.utc_now()

    1..total
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      rows =
        for n <- chunk do
          %{
            id: Ecto.UUID.dump!(UUID.uuid4()),
            event_type: "DDD.TransactionStressTest.Bumped",
            aggregate_id: "agg-#{n}",
            aggregate_type: "Stress.Counter",
            payload: %{"n" => n},
            occurred_at: DateTime.add(now, n, :microsecond),
            inserted_at: now
          }
        end

      Repo.insert_all("domain_events", rows)
    end)
  end
end
