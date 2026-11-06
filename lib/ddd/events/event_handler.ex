defmodule DDD.EventHandler do
  @moduledoc """
  A handler for domain events delivered through the outbox.

      defmodule MyApp.OnOrderPlaced do
        use DDD.EventHandler, events: [MyApp.Events.OrderPlaced]

        @impl DDD.EventHandler
        def handle(%MyApp.Events.OrderPlaced{} = event) do
          case MyApp.Commands.ReserveStock.call(%{order_id: event.aggregate_id}) do
            {:ok, _} -> :ok
            {:error, error} -> {:error, error}
          end
        end
      end

      MyApp.OnOrderPlaced.subscribe()

  ## What `handle/1` returns

    * `:ok` (or `{:ok, _}`, or any other non-error value): the event was handled.
    * `{:error, reason}`: it depends on the kind of the error.
      * A **business** error (`%DDD.Error{kind: :business}`, or any plain reason such as
        `:not_found`) means the handler looked at the event and said no. That outcome is
        deterministic, so it is **recorded as rejected and never retried**. It is not a dead
        letter.
      * An **infrastructure** error (`%DDD.Error{kind: :infrastructure}`, for example a
        conflict or a failed transaction) is a temporary failure: the event is **retried**
        with a backoff and dead-lettered if it keeps failing.
    * An exception, throw or crash is unexpected: retried like an infrastructure error.

  In both failure cases a transactional handler is rolled back, so it never leaves half of
  its work behind.

  ## Transactions and delivery guarantees

  By default each delivery runs in its own database transaction together with a record in
  `event_deliveries` that this handler processed this event. If the handler fails, everything
  rolls back, including the record, and the event is retried later. If it succeeds, the handler
  is never run again for that event, even when another handler of the same event failed and the
  event is retried. For handlers that only write to our database that is effectively
  exactly-once. Events a handler produces by saving aggregates commit with its work.

      use DDD.EventHandler, events: [...]                      # transaction on the configured repo
      use DDD.EventHandler, events: [...], repo: MyApp.Repo     # another repo
      use DDD.EventHandler, events: [...], transaction: false   # no transaction

  A handler with an effect a transaction can't roll back (sending an email, calling an API)
  should use `transaction: false`. It is then delivered at least once: if the server stops
  after the effect but before the delivery is recorded, it runs again, so it must tolerate that.

  Handlers that don't `use DDD.EventHandler` (any module with `handle/1`) still work and are
  delivered like `transaction: false` handlers.
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  @callback handle(event :: struct()) :: :ok | {:ok, any()} | {:error, any()}

  defmacro __using__(opts) do
    events = Keyword.fetch!(opts, :events)
    transaction? = Keyword.get(opts, :transaction, true)
    repo = Keyword.get(opts, :repo, :default)

    quote do
      @behaviour DDD.EventHandler

      @doc false
      def __handler_events__, do: unquote(events)

      @doc false
      def __handler_repo__,
        do: if(unquote(transaction?), do: DDD.Config.repo(unquote(repo)), else: nil)

      @doc "Subscribe to this handler's events on `DDD.EventBus`."
      def subscribe, do: Enum.each(__handler_events__(), &DDD.EventBus.subscribe(&1, __MODULE__))

      @doc "Remove this handler's subscriptions."
      def unsubscribe,
        do: Enum.each(__handler_events__(), &DDD.EventBus.unsubscribe(&1, __MODULE__))
    end
  end

  @typedoc """
    * `:delivered` - the handler ran and succeeded
    * `:skipped` - it had already processed (or rejected) this event
    * `{:rejected, reason}` - a business error: recorded, never retried
    * `{:error, reason}` - a failure to retry (infrastructure error, exception)
  """
  @type result :: :delivered | :skipped | {:rejected, term()} | {:error, term()}

  @doc """
  Deliver `event` (stored under `event_id`, the 16-byte outbox id) to `handler`.

  `fallback_repo` is used for the delivery record of non-transactional handlers.
  """
  @spec deliver(module(), struct(), binary(), module()) :: result()
  def deliver(handler, event, event_id, fallback_repo) do
    DDD.Telemetry.span(
      [:ddd, :handler, :deliver],
      %{handler: handler, event: event.__struct__},
      fn ->
        result = do_deliver(handler, event, event_id, fallback_repo)
        {result, %{outcome: outcome(result)}}
      end
    )
  end

  defp outcome({:rejected, _}), do: :rejected
  defp outcome({:error, _}), do: :error
  defp outcome(other), do: other

  defp do_deliver(handler, event, event_id, fallback_repo) do
    name = inspect(handler)

    result =
      case transaction_repo(handler) do
        nil -> deliver_without_transaction(handler, event, event_id, name, fallback_repo)
        repo -> deliver_in_transaction(handler, event, event_id, name, repo)
      end

    with {:rejected, reason} <- result do
      # Recorded after the rollback, so the work is undone but the rejection is remembered.
      repo = transaction_repo(handler) || fallback_repo
      record_delivery(repo, event_id, name, "rejected", describe(reason))

      Logger.warning(
        "[handler] #{name} rejected #{inspect(event.__struct__)}: #{describe(reason)}"
      )

      result
    end
  end

  defp transaction_repo(handler) do
    if Code.ensure_loaded?(handler) and function_exported?(handler, :__handler_repo__, 0),
      do: handler.__handler_repo__(),
      else: nil
  end

  defp deliver_in_transaction(handler, event, event_id, name, repo) do
    result =
      repo.transaction(fn ->
        case record_delivery(repo, event_id, name, "delivered", nil) do
          :already_delivered ->
            :skipped

          :recorded ->
            case run_in_unit_of_work(handler, event) do
              :ok -> :delivered
              {:reject, reason} -> repo.rollback({:rejected, reason})
              {:retry, reason} -> repo.rollback({:retry, reason})
            end
        end
      end)

    case result do
      {:ok, outcome} ->
        outcome

      {:error, {:rejected, reason}} ->
        {:rejected, reason}

      {:error, {:retry, reason}} ->
        {:error, reason}

      # The handler ran a nested transaction that rolled back (a failed command, say) and still
      # returned success. The delivery transaction is doomed, so nothing was kept: retry it.
      {:error, :rollback} ->
        {:error,
         DDD.Error.infrastructure(
           code: :transaction_rolled_back,
           message: "the handler's transaction was rolled back",
           context: %{handler: handler}
         )}
    end
  end

  # What the handler saves through repositories is written once, just before the delivery
  # transaction commits. A failed write is a failure of the system: the event is retried.
  defp run_in_unit_of_work(handler, event) do
    case DDD.UnitOfWork.execute(fn -> run(handler, event) end, &(&1 == :ok)) do
      {:ok, outcome} -> outcome
      {:flush_failed, error} -> {:retry, error}
    end
  end

  defp deliver_without_transaction(handler, event, event_id, name, repo) do
    if delivered?(repo, event_id, name) do
      :skipped
    else
      case run(handler, event) do
        :ok ->
          record_delivery(repo, event_id, name, "delivered", nil)
          :delivered

        {:reject, reason} ->
          {:rejected, reason}

        {:retry, reason} ->
          {:error, reason}
      end
    end
  end

  # Classify what the handler did: `:ok`, `{:reject, reason}` (a business answer) or
  # `{:retry, reason}` (infrastructure failure, exception, throw).
  defp run(handler, event) do
    case handler.handle(event) do
      {:error, %DDD.Error{kind: :infrastructure} = error} -> {:retry, error}
      {:error, reason} -> {:reject, reason}
      _ok -> :ok
    end
  rescue
    exception ->
      Logger.warning("[handler] #{inspect(handler)} raised: #{Exception.message(exception)}")
      {:retry, DDD.Error.wrap(exception, %{handler: handler})}
  catch
    kind, value ->
      {:retry, DDD.Error.infrastructure(code: :thrown, message: inspect({kind, value}))}
  end

  # The unique (event_id, handler) index makes this safe against concurrent deliveries: a
  # second insert waits for the first transaction to finish, then sees the conflict.
  defp record_delivery(repo, event_id, name, outcome, reason) do
    row = %{
      event_id: event_id,
      handler: name,
      outcome: outcome,
      reason: reason,
      delivered_at: DDD.Dialect.usec(DateTime.utc_now())
    }

    case repo.insert_all(DDD.Outbox.Delivery, [row], on_conflict: :nothing) do
      {1, _} -> :recorded
      {0, _} -> :already_delivered
    end
  end

  defp delivered?(repo, event_id, name) do
    repo.exists?(
      from(d in DDD.Outbox.Delivery,
        where: d.event_id == type(^event_id, :binary_id) and d.handler == ^name
      )
    )
  end

  defp describe(%DDD.Error{} = error),
    do: "#{error.code}: #{error.message}" |> String.slice(0, 500)

  defp describe(reason),
    do: reason |> inspect(limit: 20, printable_limit: 200) |> String.slice(0, 500)
end
