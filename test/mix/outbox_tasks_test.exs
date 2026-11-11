defmodule Mix.Tasks.VicOutboxTasksTest do
  # Not async: Mix.shell is global, and the tasks use the shared database connection.
  use DDD.DataCase

  alias DDD.Outbox.DeadLetters
  alias Mix.Tasks.Vic.Outbox

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp dead_letter!(error \\ "handler down") do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.insert_all("domain_events", [
      %{
        id: Ecto.UUID.dump!(id),
        event_type: "My.Events.Thing",
        aggregate_id: "agg-7",
        aggregate_type: "My.Aggregate",
        payload: %{},
        occurred_at: now,
        inserted_at: now,
        failed_at: now,
        attempts: 11,
        last_error: error
      }
    ])

    id
  end

  defp output do
    receive do
      {:mix_shell, :info, [message]} -> IO.iodata_to_binary(message) <> output()
    after
      0 -> ""
    end
  end

  describe "vic.outbox.dead_letters" do
    test "says so when there are none" do
      Outbox.DeadLetters.run([])
      assert output() =~ "No dead letters."
    end

    test "lists unresolved dead letters with the details needed to act on them" do
      id = dead_letter!("DDD.OutboxTest.Handler: db_down")
      Outbox.DeadLetters.run([])

      out = output()
      assert out =~ id
      assert out =~ "[unresolved]"
      assert out =~ "My.Events.Thing (My.Aggregate agg-7)"
      assert out =~ "after 11 attempt(s)"
      assert out =~ "db_down"
      assert out =~ "1 dead letter(s)"
    end

    test "--all includes resolved ones" do
      id = dead_letter!()
      DeadLetters.keep(Repo, id)

      Outbox.DeadLetters.run([])
      assert output() =~ "No dead letters."

      Outbox.DeadLetters.run(["--all"])
      assert output() =~ "[kept]"
    end
  end

  describe "vic.outbox.replay" do
    test "replays one dead letter" do
      id = dead_letter!()
      Outbox.Replay.run([id])

      assert output() =~ "Replaying #{id}."
      assert DeadLetters.list(Repo) == []
      assert %{rows: [[nil, 1]]} = Repo.query!("SELECT failed_at, replays FROM domain_events")
    end

    test "--all replays every unresolved dead letter" do
      dead_letter!()
      dead_letter!()
      Outbox.Replay.run(["--all"])
      assert output() =~ "Replaying 2 dead letter(s)."
    end

    test "complains about an unknown id and about missing arguments" do
      assert_raise Mix.Error, ~r/is not a dead letter/, fn ->
        Outbox.Replay.run([Ecto.UUID.generate()])
      end

      assert_raise Mix.Error, ~r/usage/, fn -> Outbox.Replay.run([]) end
    end
  end

  describe "vic.outbox.discard" do
    test "discards a dead letter" do
      id = dead_letter!()
      Outbox.Discard.run([id])

      assert output() =~ "Discarded #{id}."
      assert [%{resolution: "discarded"}] = DeadLetters.list(Repo, all: true)
    end

    test "complains about an unknown id and about missing arguments" do
      assert_raise Mix.Error, ~r/is not a dead letter/, fn ->
        Outbox.Discard.run([Ecto.UUID.generate()])
      end

      assert_raise Mix.Error, ~r/usage/, fn -> Outbox.Discard.run([]) end
    end
  end

  test "the repo can be chosen with --repo" do
    assert Outbox.DeadLetters.repo(repo: "DDD.TestRepo") == DDD.TestRepo
    assert Outbox.DeadLetters.repo([]) == DDD.TestRepo
  end
end
