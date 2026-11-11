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
       event is skipped. The events of one aggregate are delivered one after another, in the
       order they happened; different aggregates are delivered concurrently (`:concurrency`).
    3. **Mark.** The events of the batch that every handler succeeded or rejected (a business
       error is a recorded rejection, never retried) are marked published, in one statement. A
       system failure
       (infrastructure error, exception) is retried after a backoff, and after `:max_retries`
       retries the event is dead-lettered (`failed_at` is set, it is no longer claimed, and a
       `[:ddd, :outbox, :dead_letter]` telemetry event is emitted).

  The attempt is counted when the event is claimed, so an attempt that kills the VM still uses
  one up. If the server stops mid-delivery, the lease expires and another poll picks the event
  up again; handlers that had already succeeded are not re-run.

  ## The lease and delivery guarantees

  Every node that starts a poller claims events on its own: `FOR UPDATE SKIP LOCKED` keeps two
  nodes from taking the same event, and the lease keeps them away from an event that is being
  delivered. A batch can outlast its lease (slow handlers, many events), so before each event
  the poller renews the lease of the rest of its aggregate's events once half of it is gone. With
  fast handlers that costs no query. What you can rely on depends on the handler (see
  `DDD.EventHandler`):

    * **A transactional handler (the default) is exactly-once on your database.** The delivery
      record and the handler's writes commit together, and a second node that delivers the same
      event waits for the first and then skips it. This holds whatever the lease. It is also the
      right choice for a handler whose only action is an external call such as publishing to
      Kafka: the call happens inside the transaction, so a second node can not make it twice.
      What remains is the gap between the external system and your database: if the node dies
      after Kafka accepted the message but before the commit, the retry sends it again. Give the
      message a key a consumer can deduplicate on (the event's `event_id`). It also holds a
      connection and a transaction while the call runs, so keep the call's timeout well under
      `:lease_ms` and the database's lock and checkout timeouts.
    * **A `transaction: false` handler is at-least-once and must be idempotent.** Two nodes can
      both run it for the same event if one handler outlasts the lease (a single handler that
      takes longer than `:lease_ms` is not protected by the renewal), and a crash between the
      effect and the delivery record runs it again.

  The lease is renewed in the database's own time, so nodes with different clocks agree.

  A poll that claims a full batch polls again at once instead of waiting `:interval_ms`, so the
  interval is only how long an idle poller sleeps. A backlog drains as fast as the handlers
  allow, whatever the interval and batch size.

  ## Supervision tree setup

      children = [
        MyApp.Repo,
        DDD.EventBus,
        {DDD.Outbox.Poller, repo: MyApp.Repo, interval_ms: 3_000, batch_size: 20}
      ]

  Subscribe the handlers *before* the poller starts (an event with no subscribed handler is
  marked published straight away).

  ## Options

    * `:repo`         — (required) your Ecto.Repo
    * `:interval_ms`  — how long an idle poller sleeps between polls, in ms (default: 3_000)
    * `:batch_size`   — events claimed per poll (default: 20). A small batch keeps the lease
      short and a slow handler from holding up many events.
    * `:concurrency`  — aggregates delivered at the same time within a batch (default: 4).
      Each one holds a database connection while its handlers run, so keep it below the
      repo's `:pool_size` (a warning is logged at start-up when it is not).
    * `:event_bus`    — module with `handlers_for/1` (default: `DDD.EventBus`)
    * `:lease_ms`     — how long a claimed event is reserved (default: 30_000). It is renewed
      for the rest of an aggregate's events once half of it has passed, so it has to be longer
      than your slowest single handler, not than a whole batch.
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

  @default_interval 3_000
  @default_batch 20
  @default_concurrency 4
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
      concurrency: max(Keyword.get(opts, :concurrency, @default_concurrency), 1),
      event_bus: Keyword.get(opts, :event_bus, DDD.EventBus),
      lease_ms: Keyword.get(opts, :lease_ms, @default_lease_ms),
      max_retries:
        Keyword.get(opts, :max_retries, Keyword.get(env, :max_retries, @default_max_retries)),
      backoff_ms: Keyword.get_lazy(opts, :backoff_ms, fn -> exponential_backoff(env) end)
    }

    # Trap exits so a shutdown waits for the current poll cycle to finish instead of killing
    # the process in the middle of a database query.
    Process.flag(:trap_exit, true)

    warn_if_pool_too_small(state)
    schedule_poll(state.interval_ms)
    {:ok, state}
  end

  # Every concurrently delivered aggregate holds a connection, and so does the poller's own
  # claim; with fewer connections than that the deliveries wait for each other.
  defp warn_if_pool_too_small(state) do
    pool_size = Keyword.get(state.repo.config(), :pool_size, 10)

    if state.concurrency >= pool_size do
      Logger.warning(
        "[outbox] poller concurrency (#{state.concurrency}) is not below the pool size " <>
          "(#{pool_size}) of #{inspect(state.repo)}: deliveries will queue for a connection"
      )
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    # A full batch means more is probably waiting: go again now (through the mailbox, so a
    # `poll_now` or a shutdown is not starved), and sleep only when the backlog is gone.
    if do_poll(state) >= state.batch_size,
      do: send(self(), :poll),
      else: schedule_poll(state.interval_ms)

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:poll_now, _from, state) do
    {:reply, {:ok, do_poll(state)}, state}
  end

  defp do_poll(state) do
    rows = claim(state.repo, state.batch_size, state.lease_ms)
    claimed_at = System.monotonic_time(:millisecond)
    :telemetry.execute([:ddd, :outbox, :poll], %{claimed: length(rows)}, %{})
    delivered = deliver_batch(rows, state, claimed_at)

    try do
      mark_published(delivered, state.repo)
      length(rows)
    rescue
      exception ->
        # The handlers have run and have their delivery records, so nothing re-runs: when the
        # lease ends the events are claimed again and marked published without another delivery.
        # Until then the poller must live on, and wait its interval rather than poll in a loop.
        Logger.error(
          "[outbox] could not mark #{length(delivered)} delivered event(s) published: " <>
            Exception.message(exception)
        )

        :telemetry.execute([:ddd, :outbox, :mark_failed], %{count: length(delivered)}, %{})
        0
    end
  end

  # Returns the rows that were delivered. Events of one aggregate stay in order (the claim
  # returns them oldest first); different aggregates have no order to keep, so they run side by
  # side. A failed event does not hold back the rest of its aggregate: it is retried later.
  defp deliver_batch(rows, state, claimed_at) do
    groups = rows |> Enum.group_by(&{&1.aggregate_type, &1.aggregate_id}) |> Map.values()

    if state.concurrency <= 1 or match?([_], groups) do
      Enum.flat_map(groups, &deliver_group(&1, state, claimed_at))
    else
      groups
      |> Task.async_stream(&deliver_group(&1, state, claimed_at),
        max_concurrency: state.concurrency,
        timeout: :infinity,
        ordered: false,
        zip_input_on_exit: true
      )
      |> Enum.flat_map(fn
        {:ok, delivered} ->
          delivered

        # Never expected (`process/2` catches everything), but if a delivery process dies its
        # events keep their lease and are claimed again when it ends.
        {:exit, {group, reason}} ->
          Logger.error("[outbox] delivery of #{length(group)} event(s) died: #{inspect(reason)}")

          []
      end)
    end
  end

  # The lease was set when the batch was claimed (`refreshed_at`, in monotonic ms). A group can
  # reach an event long after that, behind slower groups or slower handlers, and by then the
  # lease may have run out and another node may have claimed the event. So before each event
  # the lease of the group's remaining events is renewed, but only once half of it is gone:
  # with fast handlers this costs no query at all.
  defp deliver_group(group, state, refreshed_at, delivered \\ [])
  defp deliver_group([], _state, _refreshed_at, delivered), do: Enum.reverse(delivered)

  defp deliver_group([row | rest] = remaining, state, refreshed_at, delivered) do
    refreshed_at = renew_lease(remaining, state, refreshed_at)
    delivered = if process(row, state) == :published, do: [row | delivered], else: delivered
    deliver_group(rest, state, refreshed_at, delivered)
  end

  defp renew_lease(rows, state, refreshed_at) do
    now = System.monotonic_time(:millisecond)

    if now - refreshed_at >= div(state.lease_ms, 2) do
      Event.extend_lease(state.repo, Enum.map(rows, & &1.id), state.lease_ms)
      now
    else
      refreshed_at
    end
  rescue
    # A database that is down now will fail the delivery itself; do not fail it here as well.
    # The next event tries again.
    exception ->
      Logger.warning("[outbox] could not renew a lease: " <> Exception.message(exception))
      refreshed_at
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
      :published
    else
      {:error, reason} -> failed(row, reason, state)
    end
  rescue
    exception ->
      Logger.error(
        "[outbox] delivering #{row.event_type} crashed: #{Exception.message(exception)}"
      )

      failed(row, DDD.Error.wrap(exception, %{}), state)
  catch
    kind, value ->
      failed(row, DDD.Error.infrastructure(code: :thrown, message: inspect({kind, value})), state)
  end

  defp failed(row, reason, state) do
    fail(row, reason, state)
    :failed
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

  # One statement for the whole batch. If the node dies before it runs, the lease expires and
  # the events are claimed again; their handlers already have delivery records, so none re-runs.
  defp mark_published([] = _delivered, _repo), do: :ok

  defp mark_published(rows, repo) do
    ids = Enum.map(rows, & &1.id)

    Event
    |> where([e], e.id in ^ids)
    |> repo.update_all(
      set: [
        published_at: DDD.Dialect.usec(DateTime.utc_now()),
        locked_until: nil,
        last_error: nil
      ]
    )

    now = DateTime.utc_now()

    for row <- rows do
      :telemetry.execute(
        [:ddd, :outbox, :published],
        %{count: 1, delay_ms: DateTime.diff(now, row.occurred_at, :millisecond)},
        %{event_type: row.event_type}
      )

      Logger.debug(
        "[outbox] published #{row.event_type} (#{row.aggregate_type} #{row.aggregate_id})"
      )
    end

    :ok
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
  #
  # An unknown name is looked up by file name (`:code.where_is_file/1`, about 0.04 ms) and not
  # by listing every available module (`:code.all_available/0`, about 20 ms): a backlog of events
  # of a type that no longer exists would otherwise spend that on every attempt of every event.
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

  # Only a module name is looked up: the text comes from the database and becomes part of a
  # file name, so anything with a path separator or other odd character is not a module.
  defp available_module(full_name) do
    if full_name =~ ~r/\AElixir(\.[A-Za-z_][A-Za-z0-9_]*)+\z/ and
         :code.where_is_file(String.to_charlist(full_name <> ".beam")) != :non_existing,
       do: String.to_atom(full_name),
       else: nil
  end

  @doc false
  # Rebuild the event struct from an outbox row (`id`, `event_type`, `aggregate_id`,
  # `aggregate_type`, `payload`, `occurred_at`). Also used to replay events into a projection.
  def build_event(row) do
    with {:ok, event_module} <- resolve_module(row.event_type) do
      payload = event_module |> DDD.DomainEvent.load_payload(atomize_keys(row.payload))
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
