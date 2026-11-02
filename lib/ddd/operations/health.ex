defmodule DDD.Health do
  @moduledoc """
  A health check for the parts of the framework that can fall behind silently: the database,
  the outbox and the projections.

      DDD.Health.check()
      # => %{
      #      status: :ok,
      #      checks: %{
      #        database: %{status: :ok},
      #        outbox: %{status: :ok, pending: 0, in_flight: 0, dead_letters: 0,
      #                  oldest_pending_age_ms: 0},
      #        projections: %{"MyApp.Projections.ListSummary" => %{status: :ok, pending: 0, ...}}
      #      }
      #    }

  The overall `:status` is the worst of the checks:

    * `:unhealthy` - the database does not answer
    * `:degraded` - the outbox has unresolved dead letters, or its oldest pending event (or a
      projection's oldest unprocessed event) has waited longer than the threshold
    * `:ok`

  The result is JSON-encodable, so serve it from a Plug route, a Phoenix controller, or the MCP
  server (`DDD.Health.Query`). `mix vic.health` prints it and exits non-zero unless `:ok`.

  ## Options

  Each falls back to `config :vicander, :health, ...`, then to the default:

    * `:repo` - default: the configured repo (`config :vicander, repo: MyApp.Repo`)
    * `:projections` - the projection modules to check (default `[]`)
    * `:max_outbox_age_ms` - default `60_000`
    * `:max_dead_letters` - default `0`
    * `:max_projection_lag_ms` - default `60_000`
    * `:emit` - also emit the `DDD.Telemetry` gauges (default `true`)
  """

  @type status :: :ok | :degraded | :unhealthy

  @defaults [
    projections: [],
    max_outbox_age_ms: 60_000,
    max_dead_letters: 0,
    max_projection_lag_ms: 60_000,
    emit: true
  ]

  @spec check(keyword()) :: %{status: status(), checks: map()}
  def check(opts \\ []) do
    opts =
      @defaults
      |> Keyword.merge(Application.get_env(:vicander, :health, []))
      |> Keyword.merge(opts)

    repo = opts[:repo] || DDD.Config.repo!()

    case database(repo) do
      %{status: :ok} = database ->
        outbox = outbox(repo, opts)
        projections = projections(opts)
        if opts[:emit], do: emit(repo, opts[:projections])

        checks = %{database: database, outbox: outbox, projections: projections}
        %{status: worst([database, outbox | Map.values(projections)]), checks: checks}

      database ->
        %{status: :unhealthy, checks: %{database: database, outbox: nil, projections: %{}}}
    end
  end

  @doc "True when `check/1` reports `:ok`."
  @spec healthy?(keyword()) :: boolean()
  def healthy?(opts \\ []), do: check(opts).status == :ok

  defp database(repo) do
    case repo.query("SELECT 1") do
      {:ok, _} -> %{status: :ok}
      {:error, error} -> %{status: :unhealthy, error: Exception.message(error)}
    end
  rescue
    exception -> %{status: :unhealthy, error: Exception.message(exception)}
  end

  defp outbox(repo, opts) do
    stats = DDD.Telemetry.outbox_stats(repo)

    problems =
      [
        stats.dead_letters > opts[:max_dead_letters] &&
          "#{stats.dead_letters} unresolved dead letter(s)",
        stats.oldest_pending_age_ms > opts[:max_outbox_age_ms] &&
          "the oldest pending event has waited #{stats.oldest_pending_age_ms}ms"
      ]
      |> Enum.filter(& &1)

    stats
    |> Map.put(:status, if(problems == [], do: :ok, else: :degraded))
    |> put_problems(problems)
  end

  defp projections(opts) do
    for projection <- opts[:projections], into: %{} do
      lag = projection.lag()

      problems =
        if lag.oldest_pending_age_ms > opts[:max_projection_lag_ms],
          do: ["the oldest unprocessed event has waited #{lag.oldest_pending_age_ms}ms"],
          else: []

      {inspect(projection),
       lag
       |> Map.put(:status, if(problems == [], do: :ok, else: :degraded))
       |> put_problems(problems)}
    end
  end

  defp put_problems(map, []), do: map
  defp put_problems(map, problems), do: Map.put(map, :problems, problems)

  defp emit(repo, projections), do: DDD.Telemetry.report(repo, projections)

  defp worst(checks) do
    statuses = Enum.map(checks, & &1.status)

    cond do
      :unhealthy in statuses -> :unhealthy
      :degraded in statuses -> :degraded
      true -> :ok
    end
  end
end
