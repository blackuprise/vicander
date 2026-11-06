defmodule DDD.OutboxBatchingTest do
  @moduledoc """
  How the poller works through a backlog: it polls again at once while batches come back full,
  keeps the events of one aggregate in order while different aggregates run side by side, marks
  a batch published with one statement, and one failing event holds nothing back.
  """
  use DDD.DataCase

  import ExUnit.CaptureLog

  alias DDD.Outbox.Poller

  @moduletag :capture_log

  defmodule Ping do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :n, :integer
    end
  end

  defmodule Recorder do
    @moduledoc false
    use DDD.EventHandler, events: [DDD.OutboxBatchingTest.Ping]

    @impl DDD.EventHandler
    def handle(event) do
      send(
        :persistent_term.get({DDD.OutboxBatchingTest, :pid}),
        {:handled, event.aggregate_id, event.n}
      )

      if {event.aggregate_id, event.n} in :persistent_term.get({DDD.OutboxBatchingTest, :fail}) do
        {:error, DDD.Error.infrastructure(code: :boom, message: "boom")}
      else
        :ok
      end
    end
  end

  defmodule Shouted do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :n, :integer
    end
  end

  defmodule Note do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :text, :string, required: true
    end

    defop shout(note, n) do
      emit_event(note, DDD.OutboxBatchingTest.Shouted.new(%{n: n}))
    end
  end

  defmodule NotePort do
    @moduledoc false
    use DDD.Repository

    repo Note do
    end
  end

  defmodule Notes do
    @moduledoc false
    use DDD.Repository.Ecto, port: NotePort, repo: DDD.TestRepo, table: "batch_notes"
  end

  setup do
    :persistent_term.put({__MODULE__, :pid}, self())
    :persistent_term.put({__MODULE__, :fail}, [])
    DDD.EventBus.subscribe(Ping, Recorder)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :pid})
      :persistent_term.erase({__MODULE__, :fail})
      DDD.EventBus.unsubscribe(Ping, Recorder)
    end)
  end

  defp start_poller(opts) do
    stop_supervised(DDD.Outbox.Poller)

    start_supervised!(
      {DDD.Outbox.Poller,
       [repo: Repo, interval_ms: 600_000, backoff_ms: fn _ -> 600_000 end] ++ opts}
    )
  end

  # Events of the aggregate `aggregate` numbered `ns`, oldest first.
  defp insert_events(aggregate, ns) do
    now = DateTime.utc_now()

    rows =
      for n <- ns do
        %{
          id: Ecto.UUID.dump!(UUID.uuid4()),
          event_type: "DDD.OutboxBatchingTest.Ping",
          aggregate_id: aggregate,
          aggregate_type: "Batching.Aggregate",
          payload: %{"n" => n},
          occurred_at: DateTime.add(now, n, :millisecond),
          inserted_at: now
        }
      end

    Repo.insert_all("domain_events", rows)
  end

  defp published, do: scalar("SELECT count(*) FROM domain_events WHERE published_at IS NOT NULL")
  defp scalar(sql), do: Repo.query!(sql).rows |> hd() |> hd()

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out waiting")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp handled(acc \\ []) do
    receive do
      {:handled, aggregate, n} -> handled([{aggregate, n} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a full batch is followed by another poll at once, not after the interval" do
    start_poller(batch_size: 2)
    insert_events("a", 1..7)

    # The interval is ten minutes: only the repoll can deliver more than the first 2.
    send(Process.whereis(Poller), :poll)

    wait_until(fn -> published() == 7 end)
    assert length(handled()) == 7
  end

  # The test repo, except that marking events published fails while `:fail_mark` is set.
  defmodule FlakyRepo do
    @moduledoc false
    for {name, arity} <- DDD.TestRepo.__info__(:functions), name != :update_all do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: DDD.TestRepo.unquote(name)(unquote_splicing(args))
    end

    def update_all(queryable, updates, opts \\ []) do
      if :persistent_term.get({DDD.OutboxBatchingTest, :fail_mark}, false) and
           Keyword.has_key?(updates[:set] || [], :published_at),
         do: raise(DBConnection.ConnectionError, "connection lost"),
         else: DDD.TestRepo.update_all(queryable, updates, opts)
    end
  end

  test "a failure while marking the batch published does not take the poller down" do
    stop_supervised(DDD.Outbox.Poller)

    start_supervised!(
      {DDD.Outbox.Poller,
       [repo: FlakyRepo, interval_ms: 600_000, backoff_ms: fn _ -> 600_000 end, batch_size: 100]}
    )

    insert_events("a", 1..3)
    pid = Process.whereis(Poller)
    :persistent_term.put({__MODULE__, :fail_mark}, true)
    on_exit(fn -> :persistent_term.erase({__MODULE__, :fail_mark}) end)

    assert {:ok, 0} = Poller.poll_now()
    assert Process.whereis(Poller) == pid
    assert published() == 0

    # The database is back: the next poll goes on (the events are leased until then).
    :persistent_term.put({__MODULE__, :fail_mark}, false)
    Repo.query!("UPDATE domain_events SET locked_until = NULL")
    assert {:ok, 3} = Poller.poll_now()
    assert published() == 3
  end

  test "an idle poller sleeps the interval instead of polling in a loop" do
    start_poller(batch_size: 5)
    insert_events("a", 1..3)

    send(Process.whereis(Poller), :poll)
    wait_until(fn -> published() == 3 end)

    # 3 < 5: that was not a full batch, so nothing polls again until the interval is over.
    insert_events("a", 4..5)
    Process.sleep(100)
    assert published() == 3
  end

  for concurrency <- [1, 4] do
    test "the events of one aggregate stay in order (concurrency #{concurrency})" do
      start_poller(batch_size: 100, concurrency: unquote(concurrency))

      for aggregate <- ~w(a b c d e), do: insert_events(aggregate, 1..6)
      assert {:ok, 30} = Poller.poll_now()

      per_aggregate = handled() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      assert map_size(per_aggregate) == 5

      for {_aggregate, ns} <- per_aggregate, do: assert(ns == Enum.sort(ns))
      assert published() == 30
    end
  end

  test "a failing event is retried alone: its aggregate's later events and the others go on" do
    start_poller(batch_size: 100, concurrency: 4, max_retries: 5)
    :persistent_term.put({__MODULE__, :fail}, [{"a", 2}])

    insert_events("a", 1..3)
    insert_events("b", 1..3)
    assert {:ok, 6} = Poller.poll_now()

    assert published() == 5

    assert [[2, error]] =
             Repo.query!(
               "SELECT (payload->>'n')::int, last_error FROM domain_events WHERE published_at IS NULL"
             ).rows

    assert error =~ "boom"
  end

  test "a batch is marked published with one statement" do
    start_poller(batch_size: 100, concurrency: 4)
    insert_events("a", 1..4)
    insert_events("b", 1..4)

    parent = self()
    id = "mark-#{inspect(make_ref())}"

    :telemetry.attach(
      id,
      [:ddd, :test_repo, :query],
      fn _, _, %{query: query}, _ ->
        if query =~ ~s(UPDATE "domain_events") and query =~ "published_at",
          do: send(parent, :marked)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert {:ok, 8} = Poller.poll_now()
    assert_received :marked
    refute_received :marked
  end

  test "the published telemetry still fires for every event of the batch" do
    start_poller(batch_size: 100)
    insert_events("a", 1..3)

    parent = self()
    id = "published-#{inspect(make_ref())}"

    :telemetry.attach(
      id,
      [:ddd, :outbox, :published],
      fn _, measurements, _, _ -> send(parent, {:published, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert {:ok, 3} = Poller.poll_now()
    for _ <- 1..3, do: assert_received({:published, %{count: 1, delay_ms: _}})
  end

  test "warns when the concurrency is not below the pool size" do
    log = capture_log(fn -> start_poller(concurrency: 50) end)
    assert log =~ "poller concurrency (50) is not below the pool size"

    refute capture_log(fn -> start_poller(concurrency: 2) end) =~ "pool size"
  end

  test "an aggregate's events are written to the outbox with one insert" do
    Repo.query!("""
    CREATE TEMP TABLE batch_notes (
      id uuid PRIMARY KEY, text varchar,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    {:ok, note} = DDD.OutboxBatchingTest.Note.new(text: "a")
    {:ok, note} = DDD.OutboxBatchingTest.Note.shout(note, 1)
    {:ok, note} = DDD.OutboxBatchingTest.Note.shout(note, 2)
    {:ok, note} = DDD.OutboxBatchingTest.Note.shout(note, 3)

    parent = self()
    id = "insert-#{inspect(make_ref())}"

    :telemetry.attach(
      id,
      [:ddd, :test_repo, :query],
      fn _, _, %{query: query}, _ ->
        if query =~ ~s(INSERT INTO "domain_events"), do: send(parent, :events_insert)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert {:ok, _} = DDD.OutboxBatchingTest.Notes.save(note)
    assert_received :events_insert
    refute_received :events_insert
    assert scalar("SELECT count(*) FROM domain_events") == 3
  end

  test "an aggregate with no events writes nothing to the outbox" do
    Repo.query!("""
    CREATE TEMP TABLE batch_notes (
      id uuid PRIMARY KEY, text varchar,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    {:ok, note} = DDD.OutboxBatchingTest.Note.new(text: "quiet")
    assert {:ok, %{version: 1}} = DDD.OutboxBatchingTest.Notes.save(note)
    assert scalar("SELECT count(*) FROM domain_events") == 0
  end
end
