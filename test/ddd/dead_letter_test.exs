defmodule DDD.DeadLetterTest do
  use DDD.DataCase

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  alias DDD.Outbox.{DeadLetterHandler, DeadLetters, Poller}
  alias DDD.Outbox.DeadLetterPolicy.Default

  defmodule Replay do
    @moduledoc false
    @behaviour DDD.Outbox.DeadLetterPolicy
    def handle(_dead_letter), do: :replay
  end

  defmodule Discard do
    @moduledoc false
    @behaviour DDD.Outbox.DeadLetterPolicy
    def handle(_dead_letter), do: :discard
  end

  defmodule Later do
    @moduledoc false
    @behaviour DDD.Outbox.DeadLetterPolicy
    def handle(_dead_letter), do: :later
  end

  defmodule Buggy do
    @moduledoc false
    @behaviour DDD.Outbox.DeadLetterPolicy
    def handle(_dead_letter), do: raise("policy bug")
  end

  defmodule Garbage do
    @moduledoc false
    @behaviour DDD.Outbox.DeadLetterPolicy
    def handle(_dead_letter), do: :nonsense
  end

  # Inserts an event that is already dead-lettered, `age_s` seconds ago.
  defp dead_letter!(attrs \\ []) do
    id = UUID.uuid4()
    failed_at = DateTime.add(DateTime.utc_now(), -Keyword.get(attrs, :age_s, 120), :second)

    Repo.insert_all("domain_events", [
      %{
        id: Ecto.UUID.dump!(id),
        event_type: Keyword.get(attrs, :event_type, "Some.Event"),
        aggregate_id: "agg-1",
        aggregate_type: "My.Aggregate",
        payload: %{},
        occurred_at: DateTime.add(failed_at, -60, :second),
        inserted_at: failed_at,
        failed_at: failed_at,
        attempts: 11,
        last_error: "handler down",
        replays: Keyword.get(attrs, :replays, 0)
      }
    ])

    id
  end

  defp row(id) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT resolution, resolved_at IS NOT NULL, failed_at IS NOT NULL, attempts, replays
          FROM domain_events WHERE id = $1
        """,
        [Ecto.UUID.dump!(id)]
      )

    List.to_tuple(row)
  end

  defp start_handler(opts) do
    defaults = [repo: Repo, sweep_interval_ms: 600_000]
    start_supervised!({DeadLetterHandler, Keyword.merge(defaults, opts)})
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition was not met in time")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:vicander, :dead_letters) end)
  end

  describe "DeadLetters" do
    test "list/2 returns unresolved dead letters, oldest first, with readable fields" do
      newer = dead_letter!(age_s: 10)
      older = dead_letter!(age_s: 100)

      assert [first, second] = DeadLetters.list(Repo)
      assert [first.id, second.id] == [older, newer]

      assert %{
               event_type: "Some.Event",
               aggregate_type: "My.Aggregate",
               aggregate_id: "agg-1",
               attempts: 11,
               last_error: "handler down",
               replays: 0,
               resolution: nil,
               resolved_at: nil
             } = first

      assert %DateTime{} = first.failed_at
    end

    test "events that are not dead letters are never listed" do
      Repo.insert_all("domain_events", [
        %{
          id: Ecto.UUID.dump!(UUID.uuid4()),
          event_type: "Fine",
          aggregate_id: "1",
          aggregate_type: "X",
          payload: %{},
          occurred_at: DateTime.utc_now(),
          inserted_at: DateTime.utc_now()
        }
      ])

      assert DeadLetters.list(Repo, all: true) == []
    end

    test "list/2 hides resolved ones unless asked, and honours limit" do
      kept = dead_letter!(age_s: 300)
      dead_letter!(age_s: 200)
      dead_letter!(age_s: 100)
      DeadLetters.keep(Repo, kept)

      assert length(DeadLetters.list(Repo)) == 2
      assert length(DeadLetters.list(Repo, all: true)) == 3
      assert length(DeadLetters.list(Repo, limit: 1)) == 1
    end

    test "get/2 finds a dead letter by id" do
      id = dead_letter!()
      assert %{id: ^id} = DeadLetters.get(Repo, id)
      assert DeadLetters.get(Repo, UUID.uuid4()) == nil
    end

    test "replay/2 clears the failure state and counts the replay" do
      id = dead_letter!()
      assert :ok = DeadLetters.replay(Repo, id)

      assert {nil, false, false, 0, 1} = row(id)

      # The poller claims it again, from scratch.
      assert [%{id: claimed, attempts: 1}] = Poller.claim(Repo, 10, 60_000)
      assert claimed == id
    end

    test "keep/2 and discard/2 resolve a dead letter" do
      kept = dead_letter!()
      discarded = dead_letter!()

      assert :ok = DeadLetters.keep(Repo, kept)
      assert :ok = DeadLetters.discard(Repo, discarded)

      assert {"kept", true, true, 11, 0} = row(kept)
      assert {"discarded", true, true, 11, 0} = row(discarded)
      assert DeadLetters.list(Repo) == []
    end

    test "resolving something that is not a dead letter is an error" do
      assert {:error, :not_found} = DeadLetters.replay(Repo, UUID.uuid4())
      assert {:error, :not_found} = DeadLetters.keep(Repo, UUID.uuid4())
      assert {:error, :not_found} = DeadLetters.discard(Repo, UUID.uuid4())
    end

    test "replay_all/1 replays every unresolved dead letter" do
      a = dead_letter!()
      b = dead_letter!()
      kept = dead_letter!()
      DeadLetters.keep(Repo, kept)

      assert DeadLetters.replay_all(Repo) == 2
      assert {nil, false, false, 0, 1} = row(a)
      assert {nil, false, false, 0, 1} = row(b)
      assert {"kept", true, true, 11, 0} = row(kept)
    end

    test "claim_unresolved/3 leases dead letters" do
      id = dead_letter!()
      assert [%{id: ^id}] = DeadLetters.claim_unresolved(Repo, 10, 60_000)
      assert [] = DeadLetters.claim_unresolved(Repo, 10, 60_000)

      DeadLetters.release(Repo, id)
      assert [%{id: ^id}] = DeadLetters.claim_unresolved(Repo, 10, 60_000)
    end
  end

  describe "the default policy" do
    defp letter(attrs \\ []),
      do:
        Map.merge(
          %{replays: 0, failed_at: DateTime.add(DateTime.utc_now(), -3600, :second)},
          Map.new(attrs)
        )

    test "keeps everything unless automatic replay is configured" do
      assert Default.handle(letter()) == :keep
    end

    test "replays up to max_replays times once the cooldown has passed, then keeps" do
      Application.put_env(:vicander, :dead_letters, max_replays: 2, replay_cooldown_ms: 1_000)

      assert Default.handle(letter(replays: 0)) == :replay
      assert Default.handle(letter(replays: 1)) == :replay
      assert Default.handle(letter(replays: 2)) == :keep
    end

    test "waits while the cooldown has not passed" do
      Application.put_env(:vicander, :dead_letters, max_replays: 2, replay_cooldown_ms: 60_000)
      assert Default.handle(letter(failed_at: DateTime.utc_now())) == :later
    end
  end

  # Starts the handler and waits for its sweep at startup, capturing everything it logs. The
  # startup sweep runs on its own, so capturing only a later `sweep_now` would sometimes miss it.
  defp start_logged(opts) do
    with_log(fn ->
      pid = start_handler(opts)
      assert {:ok, _} = DeadLetterHandler.sweep_now()
      pid
    end)
  end

  describe "DeadLetterHandler" do
    test "the default policy keeps a dead letter, acknowledging it" do
      id = dead_letter!()
      {_pid, log} = start_logged([])

      assert {"kept", true, true, 11, 0} = row(id)
      assert log =~ "kept"
      assert log =~ "mix vic.outbox.replay #{id}"
    end

    test "a dead letter that exists when the handler starts is picked up at once" do
      id = dead_letter!()
      start_handler([])
      wait_until(fn -> row(id) |> elem(0) == "kept" end)
    end

    test "a :replay policy makes the event deliverable again" do
      id = dead_letter!()
      {_pid, log} = start_logged(policy: Replay)

      assert {nil, false, false, 0, 1} = row(id)
      assert log =~ "replayed automatically (replay 1)"
    end

    test "a :discard policy resolves it as discarded" do
      id = dead_letter!()
      {_pid, log} = start_logged(policy: Discard)

      assert {"discarded", true, true, 11, 0} = row(id)
      assert log =~ "discarded"
    end

    test ":later leaves it unresolved for a later sweep" do
      id = dead_letter!()
      start_logged(policy: Later)

      assert {nil, false, true, 11, 0} = row(id)
      assert [%{id: ^id}] = DeadLetters.claim_unresolved(Repo, 10, 60_000)
    end

    test "a policy that raises is logged and cannot crash the handler" do
      id = dead_letter!()
      {pid, log} = start_logged(policy: Buggy)

      assert log =~ "policy bug"
      assert Process.alive?(pid)
      assert {nil, false, true, 11, 0} = row(id)
    end

    test "a policy that returns something unknown is treated as :later" do
      id = dead_letter!()
      {pid, log} = start_logged(policy: Garbage)

      assert log =~ ":nonsense"
      assert Process.alive?(pid)
      assert {nil, false, true, 11, 0} = row(id)
    end

    test "options come from application config, and an option passed in wins" do
      Application.put_env(:vicander, :dead_letters, policy: Discard)
      id = dead_letter!()
      start_logged([])
      assert {"discarded", _, _, _, _} = row(id)
    end

    test "it sweeps periodically" do
      start_handler(policy: Discard, sweep_interval_ms: 10)
      id = dead_letter!()

      capture_log(fn -> wait_until(fn -> row(id) |> elem(0) == "discarded" end) end)
    end

    test "after a crash the supervisor restarts it and nothing is lost" do
      start_handler(policy: Discard)
      old = Process.whereis(DeadLetterHandler)

      # An unresolved dead letter that the crashed process never got to. Its periodic sweep is
      # 10 minutes away, so only the sweep at startup of the restarted process can find it.
      id = dead_letter!()

      capture_log(fn ->
        Process.exit(old, :kill)

        wait_until(fn ->
          new = Process.whereis(DeadLetterHandler)
          is_pid(new) and new != old and elem(row(id), 0) == "discarded"
        end)
      end)
    end

    test "unrelated messages are ignored" do
      pid = start_handler([])
      send(pid, :something_else)
      assert {:ok, 0} = DeadLetterHandler.sweep_now()
    end

    test "notify/0 is harmless when the handler is not running" do
      assert :ok = DeadLetterHandler.notify()
    end
  end

  describe "when the poller gives up" do
    setup do
      id = UUID.uuid4()

      Repo.insert_all("domain_events", [
        %{
          id: Ecto.UUID.dump!(id),
          event_type: "No.Such.Event",
          aggregate_id: "42",
          aggregate_type: "My.Aggregate",
          payload: %{},
          occurred_at: DateTime.utc_now(),
          inserted_at: DateTime.utc_now()
        }
      ])

      start_supervised!(
        {Poller, repo: Repo, interval_ms: 600_000, max_retries: 0, backoff_ms: fn _ -> 0 end}
      )

      %{id: id}
    end

    test "it emits telemetry and the handler resolves the dead letter", %{id: id} do
      start_handler([])
      handler_id = "dead-letter-test-#{id}"

      :telemetry.attach(
        handler_id,
        [:ddd, :outbox, :dead_letter],
        fn _event, measurements, metadata, pid ->
          send(pid, {:telemetry, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      capture_log(fn ->
        assert {:ok, 1} = Poller.poll_now()
        # The poller notified the handler; this call is queued behind that notification.
        DeadLetterHandler.sweep_now()
      end)

      assert_received {:telemetry, %{attempts: 1}, metadata}
      assert metadata.id == id
      assert metadata.event_type == "No.Such.Event"
      assert metadata.aggregate_type == "My.Aggregate"
      assert metadata.aggregate_id == "42"
      assert metadata.error =~ "unknown_event_module"

      assert {"kept", true, true, 1, 0} = row(id)
    end

    test "with automatic replay configured it is retried, up to max_replays", %{id: id} do
      Application.put_env(:vicander, :dead_letters, max_replays: 2, replay_cooldown_ms: 0)
      start_handler([])

      capture_log(fn ->
        for _ <- 1..3 do
          Poller.poll_now()
          DeadLetterHandler.sweep_now()
        end
      end)

      # Died, replayed, died, replayed, died: now kept for a person to look at.
      assert {"kept", true, true, 1, 2} = row(id)
    end
  end
end
