defmodule DDD.Command do
  @moduledoc """
  A command is the input of one use case, and it carries its own handler.

  The command declares its fields (validated on construction) and implements `execute/1`:
  load aggregates through repositories, call domain operations, save. It holds no business
  logic itself; the rules live in entities, aggregates and specifications.

  ## Usage

      defmodule MyApp.Commands.PlaceOrder do
        use DDD.Command

        command do
          field :customer_id, :string, required: true
          field :items,       :list,   required: true
          field :notes,       :string, default: nil
        end

        @impl DDD.Command
        def execute(%__MODULE__{customer_id: customer_id, items: items}) do
          with {:ok, order} <- MyApp.Order.place(%{customer_id: customer_id}),
               {:ok, order} <- MyApp.Order.add_items(order, items) do
            MyApp.Infrastructure.OrderRepository.save(order)
          end
        end
      end

      MyApp.Commands.PlaceOrder.call(%{customer_id: "c1", items: [...]})

  ## Running a command

    * `new/1` builds and validates the command: `{:ok, command}` or `{:error, %DDD.Error{}}`.
    * `call/1` takes a command struct or plain attrs (built with `new/1` first), runs
      `execute/1`, and returns its result. Any error comes back as a `DDD.Error` whose
      `context` has `:command` set to the command module.
    * `call!/1` is `call/1` that raises on failure.

  ## Transactions

  `execute/1` runs in its own database transaction by default: `{:ok, _}` commits,
  `{:error, _}` rolls back everything the handler did (every aggregate it saved, and their
  outbox events), and an exception rolls back and propagates. The repositories' own
  transactions join it.

      use DDD.Command                              # default: transaction on the configured repo
      use DDD.Command, repo: MyApp.Repo            # another repo
      use DDD.Command, transaction: false          # no transaction (e.g. in-memory repositories)

  Validation in `new/1` happens before the transaction starts.

  ## Retrying version conflicts

  Aggregates are saved with optimistic locking: a save that lost against a concurrent one fails
  with `:stale_aggregate` (an infrastructure error). A transaction the database aborts for a
  deadlock (or a serialization failure) fails with `:deadlock_detected`, also an infrastructure
  error. `retry_on_conflict: n` re-runs the whole command, on freshly loaded data, up to `n` more
  times before giving up, after either:

      use DDD.Command, retry_on_conflict: 3

  A command called from inside an open transaction is never retried (the outer transaction is
  already doomed), and neither is any other error.

  ## Loading what the command needs

  A field that holds the id (or a list of ids) of aggregates the command will use can say so:

      command do
        field :order_ids, {:array, :string}, required: true, loads: MyApp.Order
        field :carrier_id, {:ref, MyApp.Carrier}, required: true, loads: true
      end

  `loads:` names the aggregate. Where it is stored is configured once, so a command in an
  application layer names no repository and no adapter:

      config :vicander, :repositories, [
        {MyApp.Order, MyApp.OrderRepository},   # a port with impl/0, or an adapter
        {MyApp.Carrier, MyApp.CarrierRepository}
      ]

  On a `{:ref, Aggregate}` field the aggregate is already named, so `loads: true` is enough:
  `field :carrier_id, {:ref, MyApp.Carrier}, loads: true`. `loads:` also takes a port, or an
  adapter, directly.

  Before `execute/1` runs, the command reads them all with one query per repository and keeps
  them in the unit of work (`DDD.UnitOfWork`), so the `find_by_id` calls in `execute/1` return
  them without another query. `execute/1` is written the same with or without `loads:`.

  An id that does not exist fails the command before it starts, with a `:business` error with
  code `:not_found`: `entity` is the aggregate, `entity_id` the first missing id and `details`
  has the `field` and all the `missing_ids`. If several fields are declared, the first one (in
  the order declared) with a missing id is the one reported. `nil` and `[]` load nothing.
  Aggregates the command only finds out it needs while running (`order.customer_id`) are not
  declared; they load when `find_by_id` asks for them.

  `loads:` needs the unit of work, so it cannot be used with `unit_of_work: false`.

  ## Telemetry

  Every run is a `[:ddd, :command]` span; see `DDD.Telemetry`.
  """

  require Logger

  @callback execute(command :: struct()) :: {:ok, any()} | {:error, any()}

  defmacro __using__(opts) do
    transaction? = Keyword.get(opts, :transaction, true)
    repo = Keyword.get(opts, :repo, :default)
    retries = Keyword.get(opts, :retry_on_conflict, 0)
    unit_of_work? = Keyword.get(opts, :unit_of_work, true)
    flush_order = Keyword.get(opts, :flush_order, :registration)

    if flush_order not in [:registration, :sorted] do
      raise ArgumentError,
            "`flush_order:` is :registration or :sorted, got #{inspect(flush_order)}"
    end

    quote do
      @behaviour DDD.Command
      use DDD.Params
      import DDD.Command, only: [command: 1]
      # The repo whose transaction wraps `execute/1`, or nil when transactions are off.
      @cmd_repo if(unquote(transaction?), do: unquote(repo), else: nil)
      @cmd_retries unquote(retries)
      @cmd_uow unquote(unit_of_work?)
      @cmd_flush_order unquote(flush_order)
      @before_compile DDD.Command
    end
  end

  defmacro command(do: block) do
    quote do
      DDD.Params.define_struct(unquote(block))
    end
  end

  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :params_fields) || []

    if not Module.get_attribute(env.module, :cmd_uow) and
         Enum.any?(fields, fn {_name, _type, opts} -> Keyword.has_key?(opts, :loads) end) do
      raise ArgumentError,
            "#{inspect(env.module)}: `loads:` puts the aggregates in the unit of work, which " <>
              "`unit_of_work: false` turns off"
    end

    for {name, type, opts} <- fields,
        Keyword.get(opts, :loads) == true,
        not match?({:ref, _}, type) do
      raise ArgumentError,
            "#{inspect(env.module)}: `loads: true` on :#{name} needs a `{:ref, Aggregate}` field, " <>
              "which says what to load; name the aggregate otherwise: `loads: MyApp.Order`"
    end

    quote do
      @doc """
      Run the command from a struct or attrs. Errors carry `context: %{command: #{inspect(__MODULE__)}}`.
      """
      def call(input), do: DDD.Command.call(__MODULE__, input)

      @doc "Like `call/1`, raising on failure."
      def call!(input), do: DDD.Command.call!(__MODULE__, input)

      @doc false
      def __cmd_repo__, do: DDD.Config.repo(@cmd_repo)

      @doc false
      def __cmd_retries__, do: @cmd_retries

      @doc false
      def __cmd_uow__, do: @cmd_uow

      @doc false
      def __cmd_flush_order__, do: @cmd_flush_order
    end
  end

  @doc false
  def call(module, %{__struct__: module} = command), do: run(module, command)

  def call(module, attrs) do
    case module.new(attrs) do
      {:ok, command} -> run(module, command)
      {:error, error} -> {:error, DDD.Error.wrap(error, %{command: module})}
    end
  end

  @doc false
  def call!(module, input) do
    case call(module, input) do
      {:ok, result} -> result
      {:error, error} -> raise "Command #{inspect(module)} failed: #{inspect(error)}"
    end
  end

  defp run(module, command) do
    Logger.debug("[command] #{inspect(module)} started #{inspect(Map.from_struct(command))}")

    {micros, result} =
      :timer.tc(fn ->
        DDD.Telemetry.span([:ddd, :command], %{command: module}, fn ->
          result =
            case attempt(module, command, module.__cmd_retries__(), 1) do
              {:error, reason} -> {:error, DDD.Error.wrap(reason, %{command: module})}
              other -> other
            end

          {result, DDD.Telemetry.result_metadata(result)}
        end)
      end)

    log_result(module, result, micros)
    result
  end

  # Run the command once; re-run it on a version conflict while retries remain.
  defp attempt(module, command, retries_left, attempt) do
    result = execute_once(module, command)

    if retries_left > 0 and conflict?(result) and not in_outer_transaction?(module) do
      delay_ms = retry_delay_ms(attempt)

      Logger.info(
        "[command] #{inspect(module)} lost a version conflict (attempt #{attempt}); " <>
          "retrying in #{delay_ms}ms"
      )

      :telemetry.execute(
        [:ddd, :command, :retry],
        %{attempt: attempt, delay_ms: delay_ms},
        %{command: module}
      )

      Process.sleep(delay_ms)
      attempt(module, command, retries_left - 1, attempt + 1)
    else
      result
    end
  end

  # Full jitter: a random wait up to a cap that doubles per attempt (5, 10, 20 … 200 ms). Without
  # it, everyone who lost a race re-runs at the same moment and loses against each other again.
  @retry_base_ms 5
  @retry_max_ms 200
  @doc false
  def retry_delay_ms(attempt) do
    cap = min(@retry_base_ms * Integer.pow(2, min(attempt - 1, 10)), @retry_max_ms)
    :rand.uniform(cap)
  end

  defp execute_once(module, command) do
    case module.__cmd_repo__() do
      nil -> with_unit_of_work(module, command)
      repo -> in_transaction(repo, module, command)
    end
  rescue
    exception ->
      if retryable?(module, exception) do
        # The database aborted the transaction (a deadlock): that is a result, and a retried one.
        Logger.warning(
          "[command] #{inspect(module)} was aborted: #{Exception.message(exception)}"
        )

        {:error, DDD.UnitOfWork.deadlock_error(exception)}
      else
        Logger.error("[command] #{inspect(module)} crashed: #{Exception.message(exception)}")
        reraise exception, __STACKTRACE__
      end
  end

  defp retryable?(module, exception) do
    case module.__cmd_repo__() do
      nil -> false
      repo -> DDD.Dialect.retryable?(repo, exception)
    end
  end

  # The command's repository writes are recorded and written once, when `execute/1` returns
  # `{:ok, _}` and before the transaction commits (see `DDD.UnitOfWork`). A failed write is the
  # command's error. Called inside another unit of work, it joins that one.
  defp with_unit_of_work(module, command) do
    if module.__cmd_uow__() do
      DDD.UnitOfWork.run(
        fn -> with :ok <- preload(module, command), do: module.execute(command) end,
        flush_order: module.__cmd_flush_order__()
      )
    else
      module.execute(command)
    end
  end

  # The aggregates the command declares with `field ..., loads: Repository`, read before
  # `execute/1` runs: one query per repository. One that does not exist fails the command here,
  # before it has done anything.
  defp preload(module, command) do
    declared =
      for {name, type, opts} <- module.__params__(),
          spec = Keyword.get(opts, :loads),
          do: {name, adapter!(spec, type), ids_of(Map.get(command, name))}

    missing =
      declared
      |> Enum.group_by(fn {_name, adapter, _ids} -> adapter end, fn {_, _, ids} -> ids end)
      |> Map.new(fn {adapter, ids} ->
        {adapter, DDD.UnitOfWork.preload(adapter, List.flatten(ids))}
      end)

    # Fields are checked in the order they were declared; the first with a missing id fails.
    Enum.find_value(declared, :ok, fn {name, adapter, ids} ->
      absent = Enum.filter(ids, &(to_string(&1) in Map.fetch!(missing, adapter)))
      if absent != [], do: {:error, not_found(name, adapter, absent)}
    end)
  end

  defp ids_of(nil), do: []
  defp ids_of(ids) when is_list(ids), do: Enum.reject(ids, &is_nil/1)
  defp ids_of(id), do: [id]

  # What `loads:` names, as the adapter that reads it. Three ways to say it:
  #
  #   * an aggregate (`loads: MyApp.Order`), or `true` on a `{:ref, MyApp.Order}` field, whose
  #     repository is configured once (`config :vicander, :repositories`);
  #   * a port: a module with `impl/0`, which returns the adapter configured for it;
  #   * an adapter.
  #
  # The first two are what an application layer that names no infrastructure uses.
  defp adapter!(true, {:ref, aggregate}), do: via_config!(aggregate)

  defp adapter!(spec, _type) do
    cond do
      adapter = resolve(spec) -> adapter
      aggregate?(spec) -> via_config!(spec)
      true -> raise ArgumentError, unknown_loads(spec)
    end
  end

  defp via_config!(aggregate) do
    repository = DDD.Config.repository!(aggregate)

    resolve(repository) ||
      raise ArgumentError,
            "the repository configured for #{inspect(aggregate)}, #{inspect(repository)}, is not " <>
              "an adapter, nor a port whose impl/0 is one"
  end

  # An adapter is itself; a port is the adapter its `impl/0` gives; anything else, nil.
  defp resolve(module) do
    cond do
      adapter?(module) ->
        module

      Code.ensure_loaded?(module) and function_exported?(module, :impl, 0) and
          adapter?(module.impl()) ->
        module.impl()

      true ->
        nil
    end
  end

  defp adapter?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__load_many__, 1)

  defp aggregate?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__ddd_identity__, 0)

  defp unknown_loads(spec),
    do:
      "`loads: #{inspect(spec)}` is not an aggregate, a repository adapter, nor a port whose " <>
        "impl/0 is one"

  defp not_found(field, repository, ids) do
    aggregate = repository.__aggregate__()
    ids = Enum.map(ids, &to_string/1)

    DDD.Error.new(
      entity: aggregate,
      entity_id: hd(ids),
      operation: :load,
      code: :not_found,
      message: "#{inspect(aggregate)} not found: #{Enum.join(ids, ", ")} (#{field})",
      details: %{field: field, missing_ids: ids}
    )
  end

  # Lost a race for a row (`:stale_aggregate`), or the database aborted the transaction for a
  # deadlock (`:deadlock_detected`): either way the command, run again, is likely to succeed.
  defp conflict?({:error, %DDD.Error{} = error}),
    do:
      DDD.Error.has_code?(error, :stale_aggregate) or
        DDD.Error.has_code?(error, :deadlock_detected)

  defp conflict?(_result), do: false

  defp in_outer_transaction?(module) do
    case module.__cmd_repo__() do
      nil -> false
      repo -> repo.in_transaction?()
    end
  end

  defp log_result(module, {:error, %DDD.Error{} = error}, micros) do
    codes = error |> DDD.Error.codes() |> Enum.join(", ")

    Logger.info(
      "[command] #{inspect(module)} failed in #{ms(micros)}: #{codes} " <>
        "(#{inspect(error.entity)}.#{error.operation}) #{error.message}"
    )
  end

  defp log_result(module, _ok, micros),
    do: Logger.debug("[command] #{inspect(module)} ok in #{ms(micros)}")

  defp ms(micros), do: "#{Float.round(micros / 1000, 1)}ms"

  # `{:ok, value}` commits, `{:error, reason}` rolls everything back, and an exception
  # rolls back and propagates. Repository transactions inside `execute/1` join this one.
  defp in_transaction(repo, module, command) do
    result =
      repo.transaction(fn ->
        case with_unit_of_work(module, command) do
          {:ok, value} ->
            value

          {:error, reason} ->
            repo.rollback(reason)

          other ->
            raise ArgumentError,
                  "#{inspect(module)}.execute/1 must return {:ok, _} or {:error, _}, got: #{inspect(other)}"
        end
      end)

    case result do
      {:ok, value} ->
        {:ok, value}

      # execute/1 ignored a failed inner transaction and still returned {:ok, _}.
      {:error, :rollback} ->
        {:error,
         DDD.Error.infrastructure(
           code: :transaction_rolled_back,
           message: "the command's transaction was rolled back"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
