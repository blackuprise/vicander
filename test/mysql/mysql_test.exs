defmodule DDD.MySQLTest do
  @moduledoc """
  The unit of work, the outbox and the dialect on MySQL 8. MySQL differs from Postgres in what
  the batched writes rely on (no `UPDATE ... FROM`, no `RETURNING`, changed rows rather than
  matched ones, a statement-level undo on a duplicate key), so this checks the same behaviour
  with the MySQL dialect:

      docker run -d -e MYSQL_ROOT_PASSWORD=mysql -p 3306:3306 mysql:8.0
      DB=mysql mix test --only mysql
  """
  use DDD.DataCase

  @moduletag :mysql
  @moduletag :capture_log

  alias DDD.UnitOfWork

  defmodule Renamed do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :text, :string
    end
  end

  defmodule Thing do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :text, :string, required: true
      field :n, :integer
      field :flag, :boolean
      field :amount, :decimal
      field :seen, :datetime_usec
      field :meta, :map
    end

    defop rename(thing, text) do
      thing |> Map.put(:text, text) |> emit_event(DDD.MySQLTest.Renamed.new(%{text: text}))
    end

    defop retitle(thing, text), do: Map.put(thing, :text, text)
  end

  defmodule ThingPort do
    @moduledoc false
    use DDD.Repository

    repo Thing do
    end
  end

  defmodule Things do
    @moduledoc false
    use DDD.Repository.Ecto, port: ThingPort, repo: DDD.TestRepo, table: "mysql_things"
  end

  defmodule Handler do
    @moduledoc false
    use DDD.EventHandler, events: [DDD.MySQLTest.Renamed]

    @impl DDD.EventHandler
    def handle(event) do
      if pid = :persistent_term.get({DDD.MySQLTest, :pid}, nil),
        do: send(pid, {:handled, event.text})

      DDD.TestRepo.query!(
        "INSERT INTO test_users (id, name, email) VALUES (?, ?, ?)",
        [Ecto.UUID.bingenerate(), event.text, "x@example.com"]
      )

      :ok
    end
  end

  defmodule RenameMany do
    @moduledoc false
    use DDD.Command

    command do
      field :ids, {:array, :string}, required: true, loads: DDD.MySQLTest.Things
    end

    @impl DDD.Command
    def execute(%{ids: ids}) do
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
        with {:ok, thing} <- Things.find_by_id(id),
             {:ok, thing} <- Thing.rename(thing, thing.text <> "!"),
             {:ok, thing} <- Things.save(thing) do
          {:cont, {:ok, [thing | acc]}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  setup do
    # MySQL does not undo a temporary table with the test's transaction, as Postgres does.
    Repo.query!("DROP TEMPORARY TABLE IF EXISTS mysql_things")

    Repo.query!("""
    CREATE TEMPORARY TABLE mysql_things (
      id BINARY(16) PRIMARY KEY, text VARCHAR(255), n INT, flag TINYINT(1),
      amount DECIMAL(14,4), seen DATETIME(6), meta JSON,
      created_at DATETIME(6) NOT NULL, updated_at DATETIME(6) NOT NULL,
      version BIGINT NOT NULL DEFAULT 0
    )
    """)

    :persistent_term.put({__MODULE__, :pid}, self())
    on_exit(fn -> :persistent_term.erase({__MODULE__, :pid}) end)
    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp row(id) do
    Repo.query!("SELECT text, version FROM mysql_things WHERE id = ?", [Ecto.UUID.dump!(id)]).rows
  end

  defp count(sql), do: Repo.query!(sql).rows |> hd() |> hd()
  defp events, do: count("SELECT count(*) FROM domain_events")

  defp things(n) do
    for i <- 1..n do
      {:ok, thing} = Thing.new(text: "thing #{i}")
      {:ok, saved} = Things.save(thing)
      saved
    end
  end

  defp rename_all(things, suffix) do
    for thing <- things do
      {:ok, loaded} = Things.find_by_id(thing.id)
      {:ok, renamed} = Thing.rename(loaded, loaded.text <> suffix)
      {:ok, _} = Things.save(renamed)
    end
  end

  defp all_queries(fun) do
    parent = self()
    id = "mysql-#{inspect(make_ref())}"

    :telemetry.attach(
      id,
      [:ddd, :test_repo, :query],
      fn _, _, %{query: query}, _ -> send(parent, {:query, query}) end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    {result, drain([])}
  end

  defp drain(acc) do
    receive do
      {:query, query} -> drain([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count_of(queries, pattern), do: Enum.count(queries, &(&1 =~ pattern))

  # ── the dialect ────────────────────────────────────────────────────────────

  describe "the dialect" do
    test "is the one for the MyXQL adapter, and can write in batches" do
      assert DDD.Dialect.for_repo(Repo) == DDD.Dialect.MyXQL
      assert DDD.Dialect.batch?(DDD.Dialect.MyXQL)
    end

    test "now/1 is the database's UTC time" do
      now = DDD.Dialect.MyXQL.now(Repo)
      assert abs(DateTime.diff(now, DateTime.utc_now(), :second)) < 5
      assert now.time_zone == "Etc/UTC"
    end

    test "columns/2 lists the columns of a table, and none for a missing one" do
      assert "email" in DDD.Dialect.MyXQL.columns(Repo, "test_users")
      assert "payload" in DDD.Dialect.MyXQL.columns(Repo, "domain_events")
      assert DDD.Dialect.MyXQL.columns(Repo, "no_such_table") == []
    end

    test "read_only/2 returns the result" do
      assert DDD.Dialect.MyXQL.read_only(Repo, fn -> 42 end) == 42
    end

    test "read_only/2 refuses a write when it can start the transaction itself" do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

      assert_raise MyXQL.Error, ~r/READ ONLY/, fn ->
        DDD.Dialect.MyXQL.read_only(Repo, fn ->
          Repo.query!("INSERT INTO test_users (id, name) VALUES (?, 'x')", [
            Ecto.UUID.bingenerate()
          ])
        end)
      end

      assert count("SELECT count(*) FROM test_users") == 0
    end

    test "a deadlock is retryable, and nothing else is" do
      assert DDD.Dialect.MyXQL.retryable?(%MyXQL.Error{
               mysql: %{code: 1213, name: :ER_LOCK_DEADLOCK}
             })

      refute DDD.Dialect.MyXQL.retryable?(%MyXQL.Error{mysql: %{code: 1062, name: :ER_DUP_ENTRY}})
      refute DDD.Dialect.MyXQL.retryable?(%RuntimeError{message: "no"})

      assert DDD.Dialect.retryable?(Repo, %MyXQL.Error{
               mysql: %{code: 1213, name: :ER_LOCK_DEADLOCK}
             })

      refute DDD.Dialect.retryable?(Repo, %RuntimeError{message: "no"})
    end
  end

  # ── the batched writes ─────────────────────────────────────────────────────

  describe "batched writes" do
    test "twenty changed aggregates are one UPDATE (after one locking read) and one INSERT of events" do
      notes = things(20)

      {{:ok, _}, queries} =
        all_queries(fn ->
          UnitOfWork.run(fn ->
            rename_all(notes, "!")
            {:ok, :done}
          end)
        end)

      assert count_of(queries, "UPDATE `mysql_things`") == 1
      assert count_of(queries, "FOR UPDATE") == 1
      assert count_of(queries, "INSERT INTO `domain_events`") == 1
      assert events() == 20

      for note <- notes, do: assert(row(note.id) == [[note.text <> "!", 2]])
    end

    test "twenty new aggregates are one INSERT" do
      new =
        for i <- 1..20 do
          {:ok, thing} = Thing.new(text: "new #{i}")
          thing
        end

      {{:ok, _}, queries} =
        all_queries(fn ->
          UnitOfWork.run(fn ->
            for thing <- new, do: {:ok, _} = Things.save(thing)
            {:ok, :done}
          end)
        end)

      assert count_of(queries, "INSERT INTO `mysql_things`") == 1
      for thing <- new, do: assert(row(thing.id) == [[thing.text, 1]])
    end

    test "inserts, updates, deletes and version checks are each handled" do
      [updated, deleted, checked] = things(3)
      {:ok, created} = Thing.new(text: "created")

      assert {:ok, _} =
               UnitOfWork.run(fn ->
                 {:ok, a} = Things.find_by_id(updated.id)
                 {:ok, a} = Thing.retitle(a, "updated")
                 {:ok, _} = Things.save(a)

                 {:ok, b} = Things.find_by_id(deleted.id)
                 :ok = Things.delete(b)

                 # An operation that announces something and changes nothing it stores.
                 {:ok, c} = Things.find_by_id(checked.id)
                 {:ok, c} = Thing.rename(c, c.text)
                 {:ok, _} = Things.save(c)

                 {:ok, _} = Things.save(created)
                 {:ok, :done}
               end)

      assert row(updated.id) == [["updated", 2]]
      assert row(deleted.id) == []
      assert row(created.id) == [["created", 1]]
      # Only its event was written: the row stays at the version it had.
      assert row(checked.id) == [[checked.text, 1]]
      assert events() == 1
    end

    test "every field type survives a batched insert and a batched update" do
      {:ok, thing} =
        Thing.new(
          text: "all",
          n: 7,
          flag: true,
          amount: Decimal.new("123.4567"),
          seen: ~U[2030-01-02 10:11:12.250000Z],
          meta: %{"k" => [1, 2, %{"a" => "b"}]}
        )

      assert {:ok, _} = UnitOfWork.run(fn -> Things.save(thing) end)
      assert {:ok, found} = Things.find_by_id(thing.id)
      assert {found.n, found.flag, found.seen} == {7, true, ~U[2030-01-02 10:11:12.250000Z]}
      assert Decimal.eq?(found.amount, "123.4567")
      assert found.meta == %{"k" => [1, 2, %{"a" => "b"}]}

      # Changed fields, and fields that go back to nothing.
      assert {:ok, _} =
               UnitOfWork.run(fn ->
                 {:ok, loaded} = Things.find_by_id(thing.id)

                 {:ok, changed} =
                   Thing.update(loaded,
                     text: "changed",
                     n: nil,
                     flag: false,
                     amount: nil,
                     seen: ~U[2031-05-06 07:08:09.000001Z],
                     meta: %{"z" => 1}
                   )

                 Things.save(changed)
               end)

      assert {:ok, found} = Things.find_by_id(thing.id)
      assert found.version == 2
      assert {found.text, found.n, found.flag, found.amount} == {"changed", nil, false, nil}
      assert found.seen == ~U[2031-05-06 07:08:09.000001Z]
      assert found.meta == %{"z" => 1}
    end

    test "everything that lost the race is reported together, and nothing is written" do
      [a, b, c] = things(3)

      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 rename_all([a, b, c], "!")

                 Repo.query!("UPDATE mysql_things SET version = version + 1 WHERE id != ?", [
                   Ecto.UUID.dump!(c.id)
                 ])

                 {:ok, :done}
               end)

      lost = error.details.conflicts |> Enum.map(& &1.id) |> Enum.sort()
      assert lost == Enum.sort([a.id, b.id])

      assert Enum.all?(
               error.details.conflicts,
               &(&1.expected_version == 1 and &1.actual_version == 2)
             )

      assert error.details.id == hd(error.details.conflicts).id
      assert row(c.id) == [[c.text, 1]]
      assert events() == 0
    end

    test "a new aggregate whose id already exists is a conflict, and the others are not reported",
         %{} do
      [existing] = things(1)
      {:ok, duplicate} = Thing.new(id: existing.id, text: "duplicate")
      fresh = for i <- 1..3, do: elem(Thing.new(text: "fresh #{i}"), 1)

      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 for thing <- fresh ++ [duplicate], do: {:ok, _} = Things.save(thing)
                 {:ok, :done}
               end)

      assert [%{id: id, expected_version: 0, actual_version: 1}] = error.details.conflicts
      assert id == existing.id
      assert row(existing.id) == [["thing 1", 1]]
      # The flush failed, so nothing of it stays.
      for thing <- fresh, do: assert(row(thing.id) == [])
    end

    test "a delete is guarded by the version, like a save" do
      [thing] = things(1)

      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 {:ok, loaded} = Things.find_by_id(thing.id)
                 Repo.query!("UPDATE mysql_things SET version = version + 1")
                 Things.delete(loaded)
                 {:ok, :done}
               end)

      assert {error.details.expected_version, error.details.actual_version} == {1, 2}
      assert row(thing.id) == [["thing 1", 2]]
    end

    test "deleting a row that is already gone is a conflict too" do
      [thing] = things(1)

      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 {:ok, loaded} = Things.find_by_id(thing.id)
                 Repo.query!("DELETE FROM mysql_things")
                 Things.delete(loaded)
                 {:ok, :done}
               end)

      assert error.details.actual_version == nil
    end

    test "the writes land together even without a command's transaction" do
      [thing] = things(1)
      {:ok, fresh} = Thing.new(text: "fresh")

      assert {:error, %DDD.Error{code: :stale_aggregate}} =
               UnitOfWork.run(fn ->
                 {:ok, _} = Things.save(fresh)
                 {:ok, loaded} = Things.find_by_id(thing.id)
                 {:ok, loaded} = Thing.retitle(loaded, "mine")
                 {:ok, _} = Things.save(loaded)
                 Repo.query!("UPDATE mysql_things SET version = version + 1")
                 {:ok, :done}
               end)

      assert row(fresh.id) == []
    end

    test "loads: reads the declared aggregates with one query" do
      ids = things(10) |> Enum.map(& &1.id)

      {{:ok, renamed}, queries} = all_queries(fn -> RenameMany.call(%{ids: ids}) end)

      assert length(renamed) == 10
      assert count_of(queries, "FROM `mysql_things`") == 2
      # One plain read for `loads:`, and the locking one of the UPDATE.
      assert count_of(queries, "FOR UPDATE") == 1
      assert count_of(queries, "UPDATE `mysql_things`") == 1

      assert {:error, %DDD.Error{code: :not_found, details: %{missing_ids: [missing]}}} =
               RenameMany.call(%{ids: ids ++ [missing_id = UUID.uuid4()]})

      assert missing == missing_id
    end
  end

  # ── deadlocks ──────────────────────────────────────────────────────────────

  describe "a real deadlock" do
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
        Process.sleep(200)
        lock(second)
        {:ok, :locked}
      end

      defp lock(id) do
        DDD.TestRepo.query!("SELECT id FROM test_users WHERE id = ? FOR UPDATE", [
          Ecto.UUID.dump!(id)
        ])
      end
    end

    test "is reported as :deadlock_detected and the command runs again" do
      # Two real connections and real commits: the sandbox would give both the same one.
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      a = UUID.uuid4()
      b = UUID.uuid4()

      on_exit(fn ->
        Repo.query!("DELETE FROM test_users")
        Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      end)

      for id <- [a, b],
          do:
            Repo.query!("INSERT INTO test_users (id, name) VALUES (?, 'x')", [Ecto.UUID.dump!(id)])

      parent = self()
      handler = "deadlock-#{inspect(make_ref())}"

      :telemetry.attach(
        handler,
        [:ddd, :command, :retry],
        fn _, measurements, _, _ -> send(parent, {:retried, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      results =
        [{a, b}, {b, a}]
        |> Task.async_stream(
          fn {first, second} -> CrossLock.call(%{first: first, second: second}) end,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert results == [{:ok, :locked}, {:ok, :locked}]
      # InnoDB aborted one of them at once; it was run again.
      assert_received {:retried, %{attempt: 1}}
    end
  end

  # ── the outbox ─────────────────────────────────────────────────────────────

  describe "the outbox" do
    setup do
      stop_supervised(DDD.Outbox.Poller)

      start_supervised!(
        {DDD.Outbox.Poller, repo: Repo, interval_ms: 600_000, backoff_ms: fn _ -> 0 end}
      )

      DDD.EventBus.subscribe(Renamed, Handler)
      on_exit(fn -> DDD.EventBus.unsubscribe(Renamed, Handler) end)
      :ok
    end

    test "events saved by a command are delivered to their handlers, once" do
      ids = things(3) |> Enum.map(& &1.id)
      assert {:ok, _} = RenameMany.call(%{ids: ids})
      assert events() == 3

      assert {:ok, 3} = DDD.Outbox.Poller.poll_now()
      assert_received {:handled, "thing 1!"}
      assert count("SELECT count(*) FROM domain_events WHERE published_at IS NOT NULL") == 3
      assert count("SELECT count(*) FROM event_deliveries") == 3
      assert count("SELECT count(*) FROM test_users") == 3

      # Nothing is left to deliver.
      assert {:ok, 0} = DDD.Outbox.Poller.poll_now()
      assert count("SELECT count(*) FROM test_users") == 3
    end

    test "a claim leases the events, counts the attempt, and skips what is leased" do
      ids = things(2) |> Enum.map(& &1.id)
      {:ok, _} = RenameMany.call(%{ids: ids})

      assert [%{attempts: 1}, %{attempts: 1}] = DDD.Outbox.Poller.claim(Repo, 10, 60_000)
      assert [] = DDD.Outbox.Poller.claim(Repo, 10, 60_000)
    end

    test "a handler that fails is retried, and the work it did is rolled back" do
      defmodule Failing do
        @moduledoc false
        use DDD.EventHandler, events: [DDD.MySQLTest.Renamed]

        @impl DDD.EventHandler
        def handle(_event) do
          DDD.TestRepo.query!("INSERT INTO test_users (id, name) VALUES (?, 'half')", [
            Ecto.UUID.bingenerate()
          ])

          {:error, DDD.Error.infrastructure(code: :boom, message: "boom")}
        end
      end

      DDD.EventBus.unsubscribe(Renamed, Handler)
      DDD.EventBus.subscribe(Renamed, Failing)
      on_exit(fn -> DDD.EventBus.unsubscribe(Renamed, Failing) end)

      ids = things(1) |> Enum.map(& &1.id)
      {:ok, _} = RenameMany.call(%{ids: ids})

      assert {:ok, 1} = DDD.Outbox.Poller.poll_now()
      assert count("SELECT count(*) FROM domain_events WHERE published_at IS NOT NULL") == 0
      assert count("SELECT attempts FROM domain_events") == 1
      assert count("SELECT count(*) FROM test_users") == 0
    end
  end
end
