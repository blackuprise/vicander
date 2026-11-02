defmodule DDD.Outbox.Poller do
  @moduledoc """
  GenServer that delivers the events in the `domain_events` outbox table to their handlers.

  Events are written in the same transaction as the aggregate that produced them (see
  `DDD.Repository.Ecto`). The poller then delivers each one to every handler subscribed on
  `DDD.EventBus` (see `DDD.EventHandler`):

    1. **Claim.** A batch of due events is claimed with a lease (`locked_until`) using
       `FOR UPDATE SKIP LOCKED`, so several pollers or nodes never take the same event.
    2. **Deliver.** Handlers run synchronously, each in its own transaction by default,
       together with a record in `event_deliveries`. A handler that already succeeded for this
       event is skipped.
    3. **Mark.** The event is marked published when *every* handler succeeded or rejected it
       (a business error is a recorded rejection, never retried). A system failure
       (infrastructure error, exception) is retried after a backoff, and after `:max_retries`
       retries the event is dead-lettered (`failed_at` is set, it is no longer claimed, and a
       `[:ddd, :outbox, :dead_letter]` telemetry event is emitted).

  The attempt is counted when the event is claimed, so an attempt that kills the VM still uses
  one up. If the server stops mid-delivery, the lease expires and another poll picks the event
  up again; handlers that had already succeeded are not re-run.

  ## Supervision tree setup

      children = [
        MyApp.Repo,
        DDD.EventBus,
        {DDD.Outbox.Poller, repo: MyApp.Repo, interval_ms: 500, batch_size: 100}
      ]

  Subscribe the handlers *before* the poller starts (an event with no subscribed handler is
  marked published straight away).

  ## Options

    * `:repo`         — (required) your Ecto.Repo
    * `:interval_ms`  — poll interval in ms (default: 500)
    * `:batch_size`   — events claimed per poll (default: 100)
    * `:event_bus`    — module with `handlers_for/1` (default: `DDD.EventBus`)
    * `:lease_ms`     — how long a claimed event is reserved (default: 30_000)
    * `:max_retries`  — retries after the first attempt before dead-lettering (default: 10,
      so 11 attempts)
    * `:backoff_ms`   — `fn retry -> ms end`, the wait before retry number `retry`
      (default: exponential, 1s doubling up to 5 minutes)

  `:max_retries` and the default backoff can also be set for the whole app, and an option
  passed here wins over it:

      config :vicander, :outbox, max_retries: 10, backoff_base_ms: 1_000, backoff_max_ms: 300_000
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias DDD.Outbox.Event

  @default_interval 500
  @default_batch 100
  @default_lease_ms 30_000
  @default_max_retries 10

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run a poll cycle now and return the number of events claimed (useful in tests)."
  def poll_now, do: GenServer.call(__MODULE__, :poll_now, 30_000)

  @impl GenServer
  def init(opts) do
    # Precedence: poller option > `config :vicander, :outbox` > built-in default.
    env = Application.get_env(:vicander, :outbox, [])

    state = %{
      repo: Keyword.fetch!(opts, :repo),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval),
      batch_size: Keyword.get(opts, :batch_size, @default_batch),
      event_bus: Keyword.get(opts, :event_bus, DDD.EventBus),
      lease_ms: Keyword.get(opts, :lease_ms, @default_lease_ms),
      max_retries:
        Keyword.get(opts, :max_retries, Keyword.get(env, :max_retries, @default_max_retries)),
      backoff_ms: Keyword.get_lazy(opts, :backoff_ms, fn -> exponential_backoff(env) end)
    }

    # Trap exits so a shutdown waits for the current poll cycle to finish instead of killing
    # the process in the middle of a database query.
    Process.flag(:trap_exit, true)

    schedule_poll(state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    do_poll(state)
    schedule_poll(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:poll_now, _from, state) do
    {:reply, {:ok, do_poll(state)}, state}
  end

  defp do_poll(state) do
    rows = claim(state.repo, state.batch_size, state.lease_ms)
    :telemetry.execute([:ddd, :outbox, :poll], %{claimed: length(rows)}, %{})
    Enum.each(rows, &process(&1, state))
    length(rows)
  end

  # ── Claiming ──────────────────────────────────────────────────────────────

  @doc false
  # Reserve a batch of due events for `lease_ms`. Public so it can be tested directly.
  #
  # "Due" and "leased" are judged by the database clock (`DDD.Dialect.now/1`), so nodes whose
  # clocks differ agree on them.
  def claim(repo, batch_size, lease_ms) do
    Event.claim(
      repo,
      lease_ms,
      [asc: :occurred_at],
      Event.delivery_fields(),
      [attempts: 1],
      fn now ->
        from(e in Event,
          where:
            is_nil(e.published_at) and is_nil(e.failed_at) and
              (is_nil(e.next_attempt_at) or e.next_attempt_at <= ^now) and
              (is_nil(e.locked_until) or e.locked_until <= ^now),
          order_by: e.occurred_at,
          limit: ^batch_size,
          select: e.id
        )
      end
    )
  end

  # ── Delivery ──────────────────────────────────────────────────────────────

  # One event's failure, whatever it is, is that event's failure: it is recorded and retried or
  # dead-lettered like any other, and never takes the poller (and the rest of the batch) down.
  defp process(row, state) do
    with {:ok, event} <- build_event(row),
         :ok <- deliver_all(event, row, state) do
      mark_published(state.repo, row)
    else
      {:error, reason} -> fail(row, reason, state)
    end
  rescue
    exception ->
      Logger.error(
        "[outbox] delivering #{row.event_type} crashed: #{Exception.message(exception)}"
      )

      fail(row, DDD.Error.wrap(exception, %{}), state)
  catch
    kind, value ->
      fail(row, DDD.Error.infrastructure(code: :thrown, message: inspect({kind, value})), state)
  end

  defp deliver_all(event, row, state) do
    handlers = state.event_bus.handlers_for(event.__struct__)

    errors =
      for handler <- handlers,
          {:error, reason} <- [DDD.EventHandler.deliver(handler, event, row.id, state.repo)] do
        {handler, reason}
      end

    case errors do
      [] -> :ok
      errors -> {:error, {:handlers_failed, errors}}
    end
  end

  defp mark_published(repo, row) do
    Event
    |> where([e], e.id == ^row.id)
    |> repo.update_all(
      set: [
        published_at: DDD.Dialect.usec(DateTime.utc_now()),
        locked_until: nil,
        last_error: nil
      ]
    )

    :telemetry.execute(
      [:ddd, :outbox, :published],
      %{
        count: 1,
        delay_ms: DateTime.diff(DateTime.utc_now(), row.occurred_at, :millisecond)
      },
      %{event_type: row.event_type}
    )

    Logger.info(
      "[outbox] published #{row.event_type} (#{row.aggregate_type} #{row.aggregate_id})"
    )
  end

  # `row.attempts` already counts this attempt (it is incremented when the event is claimed,
  # so even an attempt that kills the VM is counted). The first attempt is not a retry, so
  # `max_retries: 10` allows 11 attempts in total.
  defp fail(row, reason, state) do
    attempts = row.attempts
    give_up? = attempts > state.max_retries
    delay_ms = state.backoff_ms.(attempts)
    message = describe_failure(reason)

    # The retry time is compared with the database clock when claiming, so it is set from it.
    now = DDD.Dialect.for_repo(state.repo).now(state.repo)

    Event
    |> where([e], e.id == ^row.id)
    |> state.repo.update_all(
      set: [
        last_error: message,
        locked_until: nil,
        next_attempt_at: DateTime.add(now, delay_ms, :millisecond),
        failed_at: if(give_up?, do: now, else: nil)
      ]
    )

    what = "#{row.event_type} (#{row.aggregate_type} #{row.aggregate_id})"

    if give_up? do
      Logger.error("[outbox] giving up on #{what} after #{attempts} attempt(s): #{message}")

      :telemetry.execute([:ddd, :outbox, :dead_letter], %{attempts: attempts}, %{
        id: row.id,
        event_type: row.event_type,
        aggregate_type: row.aggregate_type,
        aggregate_id: row.aggregate_id,
        error: message
      })

      DDD.Outbox.DeadLetterHandler.notify()
    else
      :telemetry.execute(
        [:ddd, :outbox, :retry],
        %{attempts: attempts, delay_ms: delay_ms},
        %{event_type: row.event_type, error: message}
      )

      Logger.warning(
        "[outbox] delivery of #{what} failed (attempt #{attempts}/#{state.max_retries + 1}), " <>
          "retrying in #{delay_ms}ms: #{message}"
      )
    end
  end

  defp describe_failure({:handlers_failed, errors}) do
    errors
    |> Enum.map_join("; ", fn {handler, reason} ->
      "#{inspect(handler)}: #{describe_reason(reason)}"
    end)
    |> String.slice(0, 500)
  end

  defp describe_failure(reason), do: reason |> describe_reason() |> String.slice(0, 500)

  defp describe_reason(%DDD.Error{} = error), do: "#{error.code}: #{error.message}"
  defp describe_reason(reason), do: inspect(reason, limit: 20, printable_limit: 200)

  # 1s, 2s, 4s ... capped. Configure with `config :vicander, :outbox, backoff_base_ms: ..,
  # backoff_max_ms: ..` or pass a `backoff_ms: fn retry -> ms end` to the poller.
  defp exponential_backoff(env) do
    base = Keyword.get(env, :backoff_base_ms, 1_000)
    max = Keyword.get(env, :backoff_max_ms, 300_000)
    fn retry -> min(base * Integer.pow(2, retry - 1), max) end
  end

  # ── Rebuilding the event ──────────────────────────────────────────────────

  # The event type is a module name stored as text. A module that is not loaded yet (dev and
  # test load lazily) has no atom, so `String.to_existing_atom/1` alone would wrongly reject
  # it. We only create the atom when a module with that name exists on disk, so unknown
  # names from the database never grow the atom table.
  defp resolve_module(event_type) do
    full_name = "Elixir." <> event_type

    module =
      try do
        String.to_existing_atom(full_name)
      rescue
        ArgumentError -> available_module(full_name)
      end

    if module && Code.ensure_loaded?(module),
      do: {:ok, module},
      else: {:error, {:unknown_event_module, event_type}}
  end

  defp available_module(full_name) do
    if List.keymember?(:code.all_available(), String.to_charlist(full_name), 0),
      do: String.to_atom(full_name),
      else: nil
  end

  @doc false
  # Rebuild the event struct from an outbox row (`id`, `event_type`, `aggregate_id`,
  # `aggregate_type`, `payload`, `occurred_at`). Also used to replay events into a projection.
  def build_event(row) do
    with {:ok, event_module} <- resolve_module(row.event_type) do
      payload = atomize_keys(row.payload)
      occurred_at = parse_datetime(row.occurred_at)

      event =
        struct(event_module, payload)
        |> Map.put(:event_id, row.id)
        |> Map.put(:occurred_at, occurred_at)
        |> Map.put(:created_at, parse_datetime(payload[:created_at]) || occurred_at)
        |> Map.put(:aggregate_type, row.aggregate_type)
        |> Map.put(:aggregate_id, row.aggregate_id)

      {:ok, event}
    end
  rescue
    e -> {:error, e}
  end

  # JSON payloads carry timestamps as ISO 8601 strings; the column comes back as a naive UTC.
  defp parse_datetime(%DateTime{} = datetime), do: datetime
  defp parse_datetime(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # Keys the event no longer has (a field was removed since the row was written) have no atom to
  # become and are dropped one by one; the fields that remain are still delivered.
  defp atomize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc ->
        try do
          Map.put(acc, String.to_existing_atom(key), value)
        rescue
          ArgumentError -> acc
        end
    end)
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)
end
