defmodule DDD.ConcurrentFirstSaveTest do
  @moduledoc """
  Two commands that save the same *new* aggregate at the same moment: one wins, and the other
  gets a `:stale_aggregate` conflict, never a raw database error.

  This needs real connections and real commits, so, like `DDD.TransactionStressTest`, it
  switches the pool to `:auto` and runs on its own (`async: false`).
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias DDD.TestRepo, as: Repo
  alias Ecto.Adapters.SQL.Sandbox

  defmodule Thing do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :name, :string, required: true
    end
  end

  defmodule ThingPort do
    @moduledoc false
    use DDD.Repository

    repo Thing do
    end
  end

  defmodule Things do
    @moduledoc false
    use DDD.Repository.Ecto, port: ThingPort, repo: DDD.TestRepo, table: "first_save_things"
  end

  defmodule Create do
    @moduledoc false
    use DDD.Command

    command do
      field :id, :string, required: true
      field :name, :string, required: true
    end

    @impl DDD.Command
    def execute(%{id: id, name: name}) do
      with {:ok, thing} <- Thing.new(id: id, name: name), do: Things.save(thing)
    end
  end

  setup do
    Sandbox.mode(Repo, :auto)
    Repo.query!("DROP TABLE IF EXISTS first_save_things")

    Repo.query!("""
    CREATE TABLE first_save_things (
      id uuid PRIMARY KEY, name varchar NOT NULL,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS first_save_things")
      Sandbox.mode(Repo, :manual)
    end)
  end

  # Both start at the same moment: neither can see the other's row when it checks.
  defp race(id, names) do
    parent = self()

    tasks =
      for name <- names do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Create.call(%{id: id, name: name})
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    Task.await_many(tasks, 15_000)
  end

  test "of the same new id: one succeeds, the other is a :stale_aggregate" do
    for _round <- 1..25 do
      id = DDD.Identity.generate()

      results = race(id, ["first", "second"])

      assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))

      # A conflict the command can retry (`retry_on_conflict:`), not a raw constraint error.
      assert [{:error, %DDD.Error{code: :stale_aggregate, kind: :infrastructure}}] =
               Enum.filter(results, &match?({:error, _}, &1))

      # The winner's row is the one stored, once.
      assert Repo.query!("SELECT name, version FROM first_save_things WHERE id = $1", [
               Ecto.UUID.dump!(id)
             ]).rows == [[winner.name, 1]]
    end
  end

  test "of different new ids: both succeed" do
    results =
      for _round <- 1..10 do
        a = DDD.Identity.generate()
        b = DDD.Identity.generate()

        parent = self()

        tasks =
          for id <- [a, b] do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> Create.call(%{id: id, name: "n"})
              end
            end)
          end

        for _ <- tasks, do: assert_receive({:ready, _})
        for task <- tasks, do: send(task.pid, :go)
        Task.await_many(tasks, 15_000)
      end

    assert results |> List.flatten() |> Enum.all?(&match?({:ok, _}, &1))
  end
end
