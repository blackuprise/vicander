defmodule DDD.HealthTest do
  # Not async: Mix.shell and the application environment are global.
  use DDD.DataCase

  @moduletag :capture_log

  alias DDD.Health
  alias Mix.Tasks.Vic.Health, as: HealthTask

  defmodule BrokenRepo do
    def query("SELECT 1"), do: {:error, %RuntimeError{message: "connection refused"}}
  end

  defmodule RaisingRepo do
    def query("SELECT 1"), do: raise("pool exploded")
  end

  defmodule Caught do
    def lag, do: %{pending: 0, oldest_pending_age_ms: 0}
  end

  defmodule Lagging do
    def lag, do: %{pending: 40, oldest_pending_age_ms: 120_000}
  end

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  # Replaces the app's health config for one test, and puts the original back afterwards.
  defp put_health(config) do
    previous = Application.get_env(:vicander, :health)
    Application.put_env(:vicander, :health, config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:vicander, :health, previous),
        else: Application.delete_env(:vicander, :health)
    end)
  end

  defp insert_event(opts) do
    Repo.insert_all("domain_events", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        event_type: "My.Events.Thing",
        aggregate_id: "agg-1",
        aggregate_type: "My.Aggregate",
        payload: %{},
        occurred_at: opts[:occurred_at] || DateTime.utc_now(),
        inserted_at: DateTime.utc_now(),
        failed_at: opts[:failed_at]
      }
    ])
  end

  defp output do
    receive do
      {:mix_shell, :info, [message]} -> IO.iodata_to_binary(message) <> "\n" <> output()
    after
      0 -> ""
    end
  end

  describe "check/1" do
    test "is ok when the database answers and nothing is waiting" do
      assert %{
               status: :ok,
               checks: %{
                 database: %{status: :ok},
                 outbox: %{
                   status: :ok,
                   pending: 0,
                   in_flight: 0,
                   dead_letters: 0,
                   oldest_pending_age_ms: 0
                 },
                 projections: %{}
               }
             } = Health.check()

      assert Health.healthy?()
    end

    test "the result can be sent as JSON" do
      result = Health.check(projections: [Caught])

      assert %{"status" => "ok", "checks" => %{"projections" => %{"DDD.HealthTest.Caught" => _}}} =
               result |> Jason.encode!() |> Jason.decode!()
    end

    test "unresolved dead letters make it degraded, unless you tolerate them" do
      insert_event(failed_at: DateTime.utc_now())

      assert %{status: :degraded, checks: %{outbox: %{status: :degraded, problems: [problem]}}} =
               Health.check()

      assert problem =~ "1 unresolved dead letter"
      refute Health.healthy?()

      assert %{status: :ok} = Health.check(max_dead_letters: 1)
    end

    test "an event that has waited too long makes it degraded" do
      insert_event(occurred_at: DateTime.add(DateTime.utc_now(), -300, :second))

      assert %{status: :degraded, checks: %{outbox: %{problems: [problem]}}} = Health.check()
      assert problem =~ "the oldest pending event has waited"

      assert %{status: :ok} = Health.check(max_outbox_age_ms: 600_000)
    end

    test "a projection that is behind makes it degraded" do
      assert %{status: :degraded, checks: %{projections: projections}} =
               Health.check(projections: [Caught, Lagging])

      assert %{status: :ok, pending: 0} = projections["DDD.HealthTest.Caught"]

      assert %{status: :degraded, pending: 40, problems: [problem]} =
               projections["DDD.HealthTest.Lagging"]

      assert problem =~ "120000ms"
      assert %{status: :ok} = Health.check(projections: [Lagging], max_projection_lag_ms: 300_000)
    end

    test "a database that does not answer is unhealthy, and nothing else is read" do
      assert %{status: :unhealthy, checks: %{database: db, outbox: nil, projections: %{}}} =
               Health.check(repo: BrokenRepo, projections: [Lagging])

      assert db == %{status: :unhealthy, error: "connection refused"}

      assert %{status: :unhealthy, checks: %{database: %{error: "pool exploded"}}} =
               Health.check(repo: RaisingRepo)
    end

    test "emits the gauges unless told not to" do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "health-#{inspect(ref)}",
        [[:ddd, :outbox, :stats], [:ddd, :projection, :lag]],
        fn name, _m, _meta, _ -> send(parent, {ref, name}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("health-#{inspect(ref)}") end)

      Health.check(projections: [Caught])
      assert_received {^ref, [:ddd, :outbox, :stats]}
      assert_received {^ref, [:ddd, :projection, :lag]}

      Health.check(emit: false)
      refute_received {^ref, _}
    end

    test "options fall back to config :vicander, :health" do
      put_health(projections: [Lagging], max_projection_lag_ms: 1)

      assert %{status: :degraded, checks: %{projections: %{"DDD.HealthTest.Lagging" => _}}} =
               Health.check()

      # An option passed in the call wins over the config.
      assert %{status: :ok} = Health.check(max_projection_lag_ms: 999_999)
    end
  end

  describe "DDD.Health.Query" do
    test "is the health check as a query, for an MCP server" do
      assert {:ok, %{status: :ok, checks: %{database: %{status: :ok}}}} =
               DDD.Health.Query.call(%{})

      assert DDD.Health.Query.__description__() =~ "Health of the database"
    end
  end

  describe "mix vic.health" do
    test "prints the status and each check" do
      HealthTask.run(["--projection", "DDD.HealthTest.Caught"])

      out = output()
      assert out =~ "status: ok"
      assert out =~ "database:   ok"

      assert out =~
               "outbox:     ok (dead_letters=0, in_flight=0, oldest_pending_age_ms=0, pending=0)"

      assert out =~ "projection DDD.HealthTest.Caught: ok (oldest_pending_age_ms=0, pending=0)"
    end

    test "--json prints the result as JSON" do
      HealthTask.run(["--json"])
      assert %{"status" => "ok"} = output() |> Jason.decode!()
    end

    test "exits non-zero, saying what is wrong, when it is not ok" do
      assert {:shutdown, 1} =
               catch_exit(HealthTask.run(["--projection", "DDD.HealthTest.Lagging"]))

      assert output() =~ "projection DDD.HealthTest.Lagging: degraded"

      assert {:shutdown, 1} = catch_exit(HealthTask.run(["--repo", "DDD.HealthTest.BrokenRepo"]))
      out = output()
      assert out =~ "status: unhealthy"
      assert out =~ "database:   unhealthy - connection refused"
      refute out =~ "outbox:"
    end

    test "thresholds can be given on the command line" do
      insert_event(failed_at: DateTime.utc_now())
      assert {:shutdown, 1} = catch_exit(HealthTask.run([]))
      output()

      assert %{status: :ok} = HealthTask.run(["--max-dead-letters", "1"])
      output()
    end

    test "health_opts/1 combines configured and given projections and only what was given" do
      put_health(projections: [Caught])

      opts =
        HealthTask.health_opts(
          projection: "DDD.HealthTest.Lagging",
          projection: "DDD.HealthTest.Caught",
          max_outbox_age: 5,
          max_dead_letters: 2,
          max_projection_lag: 7
        )

      assert opts[:projections] == [Caught, Lagging]
      assert opts[:max_outbox_age_ms] == 5
      assert opts[:max_dead_letters] == 2
      assert opts[:max_projection_lag_ms] == 7
      refute Keyword.has_key?(opts, :repo)

      assert HealthTask.health_opts(repo: "My.Repo")[:repo] == My.Repo
    end
  end
end
