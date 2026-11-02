defmodule DDD.Query do
  @moduledoc """
  A query is the input of one read use case, and it carries its own handler.

  Like a `DDD.Command` it declares fields (validated on construction) and implements
  `execute/1`, but it only reads: it never saves an aggregate or emits an event.

      defmodule MyApp.Queries.OpenItems do
        use DDD.Query

        query do
          description "The items of a list that are not done yet"
          field :list_id, :uuid, required: true, description: "The list to read"
        end

        @impl DDD.Query
        def execute(%__MODULE__{list_id: id}) do
          with {:ok, list} <- MyApp.ListRepository.impl().find_by_id(id) do
            {:ok, for(item <- list.items, item.status == :open, do: %{id: item.id})}
          end
        end
      end

      MyApp.Queries.OpenItems.call(%{list_id: id})   # => {:ok, [%{id: ...}]}

  `new/1`, `call/1` and `call!/1` work as for commands, and an error comes back as a
  `DDD.Error` whose `context` has `:query` set to the query module.

  ## Read-only transaction

  `execute/1` runs in a **read-only database transaction** by default. Postgres refuses any
  write inside it, so "this cannot change data" is enforced by the database. The transaction
  also gives the query one consistent snapshot, and it is always rolled back, never committed.

      use DDD.Query                          # read-only transaction on the configured repo
      use DDD.Query, repo: MyApp.Repo        # another repo
      use DDD.Query, transaction: false      # no transaction (in-memory repositories, APIs)

  A query called from inside an open transaction (for example from a command) joins it and
  cannot make it read-only.
  """

  require Logger

  @callback execute(query :: struct()) :: {:ok, any()} | {:error, any()}

  defmacro __using__(opts) do
    transaction? = Keyword.get(opts, :transaction, true)
    repo = Keyword.get(opts, :repo, :default)

    quote do
      @behaviour DDD.Query
      use DDD.Params
      import DDD.Query, only: [query: 1]
      # The repo whose read-only transaction wraps `execute/1`, or nil when it is off.
      @query_repo if(unquote(transaction?), do: unquote(repo), else: nil)
      @before_compile DDD.Query
    end
  end

  defmacro query(do: block) do
    quote do
      DDD.Params.define_struct(unquote(block))
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "Run the query from a struct or attrs. Errors carry `context: %{query: ...}`."
      def call(input), do: DDD.Query.call(__MODULE__, input)

      @doc "Like `call/1`, raising on failure."
      def call!(input), do: DDD.Query.call!(__MODULE__, input)

      @doc false
      def __query_repo__, do: DDD.Config.repo(@query_repo)
    end
  end

  @doc false
  def call(module, %{__struct__: module} = query), do: run(module, query)

  def call(module, attrs) do
    case module.new(attrs) do
      {:ok, query} -> run(module, query)
      {:error, error} -> {:error, DDD.Error.wrap(error, %{query: module})}
    end
  end

  @doc false
  def call!(module, input) do
    case call(module, input) do
      {:ok, result} -> result
      {:error, error} -> raise "Query #{inspect(module)} failed: #{inspect(error)}"
    end
  end

  defp run(module, query) do
    Logger.info("[query] #{inspect(module)} started #{inspect(Map.from_struct(query))}")

    {micros, result} =
      :timer.tc(fn ->
        DDD.Telemetry.span([:ddd, :query], %{query: module}, fn ->
          result =
            try do
              case module.__query_repo__() do
                nil -> module.execute(query)
                repo -> read_only(repo, fn -> module.execute(query) end)
              end
            rescue
              exception ->
                Logger.error(
                  "[query] #{inspect(module)} crashed: #{Exception.message(exception)}"
                )

                reraise exception, __STACKTRACE__
            end

          result =
            case result do
              {:ok, _} = ok -> ok
              {:error, reason} -> {:error, DDD.Error.wrap(reason, %{query: module})}
              other -> raise ArgumentError, bad_result(module, other)
            end

          {result, DDD.Telemetry.result_metadata(result)}
        end)
      end)

    Logger.info("[query] #{inspect(module)} #{status(result)} in #{ms(micros)}")
    result
  end

  defp status({:ok, _}), do: "ok"
  defp status({:error, error}), do: "failed (#{error |> DDD.Error.codes() |> Enum.join(", ")})"

  defp ms(micros), do: "#{Float.round(micros / 1000, 1)}ms"

  defp bad_result(module, other),
    do: "#{inspect(module)}.execute/1 must return {:ok, _} or {:error, _}, got: #{inspect(other)}"

  @doc false
  # Run `fun` in a read-only transaction on `repo` and return its result. How a transaction is
  # made read-only differs between databases, so the repo's `DDD.Dialect` does it.
  def read_only(repo, fun), do: DDD.Dialect.for_repo(repo).read_only(repo, fun)
end
