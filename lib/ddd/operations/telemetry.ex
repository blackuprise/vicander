defmodule DDD.Telemetry do
  @moduledoc """
  The `:telemetry` events the framework emits, in one place.

  Attach with `:telemetry.attach_many/4`, or feed them to `Telemetry.Metrics` / OpenTelemetry.
  Durations are in `:native` time units (`System.convert_time_unit/3`).

  ## Spans (`:start`, `:stop`, `:exception`)

  | event prefix | metadata |
  |---|---|
  | `[:ddd, :command]` | `:command`, and on stop `:result` (`:ok`/`:error`), `:error_codes`, `:error_kind` |
  | `[:ddd, :query]` | `:query`, and on stop `:result`, `:error_codes`, `:error_kind` |
  | `[:ddd, :handler, :deliver]` | `:handler`, `:event`, and on stop `:outcome` (`:delivered`, `:skipped`, `:rejected`, `:error`) |
  | `[:ddd, :projection, :rebuild]` | `:projection`, and on stop `:events` (how many were replayed) |

  ## Counters

  | event | measurements | metadata |
  |---|---|---|
  | `[:ddd, :command, :retry]` | `%{attempt: n}` | `:command` |
  | `[:ddd, :repository, :conflict]` | `%{count: 1}` | `:aggregate`, `:id`, `:expected_version`, `:actual_version` |
  | `[:ddd, :outbox, :poll]` | `%{claimed: n}` | |
  | `[:ddd, :outbox, :published]` | `%{count: 1, delay_ms: ms}` (event age) | `:event_type` |
  | `[:ddd, :outbox, :retry]` | `%{attempts: n, delay_ms: ms}` | `:event_type`, `:error` |
  | `[:ddd, :outbox, :dead_letter]` | `%{attempts: n}` | `:id`, `:event_type`, `:aggregate_type`, `:aggregate_id`, `:error` |

  ## Gauges (call `report/1`, or let `DDD.Health` do it)

  | event | measurements | metadata |
  |---|---|---|
  | `[:ddd, :outbox, :stats]` | `%{pending, in_flight, dead_letters, oldest_pending_age_ms}` | |
  | `[:ddd, :projection, :lag]` | `%{pending, oldest_pending_age_ms}` | `:projection` |

  `report/1` reads the database and emits the gauges, so run it on a timer (for example with
  `:telemetry_poller`) and chart them; an outbox that stops draining shows as a growing
  `oldest_pending_age_ms`.
  """

  @doc "Every event name the framework emits (spans expand to start/stop/exception)."
  @spec events() :: [[atom()]]
  def events do
    spans =
      for prefix <- [
            [:ddd, :command],
            [:ddd, :query],
            [:ddd, :handler, :deliver],
            [:ddd, :projection, :rebuild]
          ],
          suffix <- [:start, :stop, :exception],
          do: prefix ++ [suffix]

    spans ++
      [
        [:ddd, :command, :retry],
        [:ddd, :repository, :conflict],
        [:ddd, :outbox, :poll],
        [:ddd, :outbox, :published],
        [:ddd, :outbox, :retry],
        [:ddd, :outbox, :dead_letter],
        [:ddd, :outbox, :stats],
        [:ddd, :projection, :lag]
      ]
  end

  @doc false
  # Run `fun` as a span. `fun` returns `{result, stop_metadata}`; the result is returned.
  def span(prefix, metadata, fun) do
    :telemetry.span(prefix, metadata, fn ->
      {result, extra} = fun.()
      {result, Map.merge(metadata, extra)}
    end)
  end

  @doc false
  # Metadata describing the result of a command or query.
  def result_metadata({:ok, _}), do: %{result: :ok}

  def result_metadata({:error, %DDD.Error{} = error}),
    do: %{result: :error, error_codes: DDD.Error.codes(error), error_kind: error.kind}

  def result_metadata({:error, reason}),
    do: %{result: :error, error_codes: [], error_kind: :business, reason: reason}

  def result_metadata(_other), do: %{result: :ok}

  @doc """
  Emit the gauges (`[:ddd, :outbox, :stats]`, and `[:ddd, :projection, :lag]` for each given
  projection) read from `repo`. Returns the outbox stats.
  """
  @spec report(module(), [module()]) :: map()
  def report(repo, projections \\ []) do
    stats = outbox_stats(repo)
    :telemetry.execute([:ddd, :outbox, :stats], stats, %{})

    for projection <- projections do
      :telemetry.execute([:ddd, :projection, :lag], projection.lag(), %{projection: projection})
    end

    stats
  end

  @doc """
  The state of the outbox, straight from the table:

    * `:pending` - waiting for delivery or a retry (not dead-lettered)
    * `:in_flight` - currently claimed by a poller
    * `:dead_letters` - given up on and not yet resolved
    * `:oldest_pending_age_ms` - how long the oldest pending event has been waiting (0 if none)
  """
  @spec outbox_stats(module()) :: %{
          pending: non_neg_integer(),
          in_flight: non_neg_integer(),
          dead_letters: non_neg_integer(),
          oldest_pending_age_ms: non_neg_integer()
        }
  def outbox_stats(repo) do
    import Ecto.Query
    alias DDD.Outbox.Event

    now = DDD.Dialect.for_repo(repo).now(repo)
    waiting = from(e in Event, where: is_nil(e.published_at) and is_nil(e.failed_at))

    oldest = repo.one(from(e in waiting, select: min(e.occurred_at)))

    %{
      pending: repo.aggregate(waiting, :count),
      in_flight: repo.aggregate(from(e in waiting, where: e.locked_until > ^now), :count),
      dead_letters:
        repo.aggregate(
          from(e in Event, where: not is_nil(e.failed_at) and is_nil(e.resolved_at)),
          :count
        ),
      oldest_pending_age_ms:
        if(oldest, do: max(DateTime.diff(now, oldest, :millisecond), 0), else: 0)
    }
  end
end
