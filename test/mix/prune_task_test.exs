defmodule Mix.Tasks.Vic.Outbox.PruneTest do
  # Not async: Mix.shell is global, and the task uses the shared database connection.
  use DDD.DataCase

  alias Mix.Tasks.Vic.Outbox.Prune

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp old_published_event do
    at = NaiveDateTime.utc_now() |> NaiveDateTime.add(-40 * 86_400, :second)

    Repo.insert_all("domain_events", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        event_type: "My.Events.Thing",
        aggregate_id: "a",
        aggregate_type: "A",
        payload: %{},
        occurred_at: at,
        inserted_at: at,
        published_at: at
      }
    ])
  end

  test "prunes and says how many" do
    old_published_event()
    old_published_event()

    Prune.run(["--older-than-days", "30"])
    assert_received {:mix_shell, :info, [message]}
    assert message == "pruned 2 event(s) older than 30 day(s)"

    Prune.run(["--older-than-days", "30", "--repo", "DDD.TestRepo"])
    assert_received {:mix_shell, :info, ["pruned 0 event(s) older than 30 day(s)"]}
  end

  test "the age is required" do
    assert_raise Mix.Error, ~r/usage: mix vic.outbox.prune --older-than-days N/, fn ->
      Prune.run([])
    end

    assert_raise Mix.Error, ~r/at least 1/, fn -> Prune.run(["--older-than-days", "0"]) end
  end
end
