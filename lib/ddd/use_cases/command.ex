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
  with `:stale_aggregate` (an infrastructure error). `retry_on_conflict: n` re-runs the whole
  command, on freshly loaded data, up to `n` more times before giving up:

      use DDD.Command, retry_on_conflict: 3

  A command called from inside an open transaction is never retried (the outer transaction is
  already doomed), and neither is any other error.

  ## Telemetry

  Every run is a `[:ddd, :command]` span; see `DDD.Telemetry`.
  """

  require Logger

  @callback execute(command :: struct()) :: {:ok, any()} | {:error, any()}

  defmacro __using__(opts) do
    transaction? = Keyword.get(opts, :transaction, true)
    repo = Keyword.get(opts, :repo, :default)
    retries = Keyword.get(opts, :retry_on_conflict, 0)

    quote do
      @behaviour DDD.Command
      use DDD.Params
      import DDD.Command, only: [command: 1]
      # The repo whose transaction wraps `execute/1`, or nil when transactions are off.
      @cmd_repo if(unquote(transaction?), do: unquote(repo), else: nil)
      @cmd_retries unquote(retries)
      @before_compile DDD.Command
    end
  end

  defmacro command(do: block) do
    quote do
      DDD.Params.define_struct(unquote(block))
    end
  end

  defmacro __before_compile__(_env) do
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
    Logger.info("[command] #{inspect(module)} started #{inspect(Map.from_struct(command))}")

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
      Logger.info(
        "[command] #{inspect(module)} lost a version conflict (attempt #{attempt}); retrying"
      )

      :telemetry.execute([:ddd, :command, :retry], %{attempt: attempt}, %{command: module})
      attempt(module, command, retries_left - 1, attempt + 1)
    else
      result
    end
  end

  defp execute_once(module, command) do
    case module.__cmd_repo__() do
      nil -> module.execute(command)
      repo -> in_transaction(repo, module, command)
    end
  rescue
    exception ->
      Logger.error("[command] #{inspect(module)} crashed: #{Exception.message(exception)}")
      reraise exception, __STACKTRACE__
  end

  defp conflict?({:error, %DDD.Error{} = error}), do: DDD.Error.has_code?(error, :stale_aggregate)
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
    do: Logger.info("[command] #{inspect(module)} ok in #{ms(micros)}")

  defp ms(micros), do: "#{Float.round(micros / 1000, 1)}ms"

  # `{:ok, value}` commits, `{:error, reason}` rolls everything back, and an exception
  # rolls back and propagates. Repository transactions inside `execute/1` join this one.
  defp in_transaction(repo, module, command) do
    result =
      repo.transaction(fn ->
        case module.execute(command) do
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
