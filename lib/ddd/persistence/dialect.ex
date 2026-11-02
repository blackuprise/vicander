defmodule DDD.Dialect do
  @moduledoc """
  The few things that differ between databases.

  Almost everything the framework does against the database is an Ecto query, so it runs on
  whatever adapter the application's repo uses. What cannot be expressed in Ecto is behind this
  behaviour, and the implementation is chosen from the repo's adapter:

  | Ecto adapter             | Dialect                |
  |--------------------------|------------------------|
  | `Ecto.Adapters.Postgres` | `DDD.Dialect.Postgres` |

  The framework has no dependency on a driver: the application adds the one it needs (for
  example `postgrex`), and the dialect follows from the repo. For an adapter that has no
  dialect here, write one and name it in the configuration:

      config :vicander, dialect: MyApp.Dialect

  A repo that has no dialect raises `ArgumentError` the first time the framework needs one,
  naming the adapter, rather than running SQL it does not understand.
  """

  @doc """
  `query` with the lock that makes a claim skip rows another transaction has locked
  (`FOR UPDATE SKIP LOCKED`), or `query` unchanged when the database has none. Unchanged, the
  claim relies on the database serialising writers, which is only correct for a single node.

  Ecto accepts only a literal lock, so the dialect applies it rather than naming it.
  """
  @callback lock_for_claim(Ecto.Query.t()) :: Ecto.Query.t()

  @doc """
  The database's current time in UTC.

  Leases and retry times are compared with this clock, never with the clock of the node that
  wrote them, so nodes whose clocks differ still agree on when a lease is over.
  """
  @callback now(repo :: module()) :: DateTime.t()

  @doc """
  Run `fun` in a read-only transaction on `repo` and return its result. The transaction is
  rolled back, so nothing it did, including switching the mode on, outlives the call.
  """
  @callback read_only(repo :: module(), fun :: (-> result)) :: result when result: term()

  @doc "The names of the columns of `table`, as the database reports them."
  @callback columns(repo :: module(), table :: String.t()) :: [String.t()]

  @adapters %{Ecto.Adapters.Postgres => DDD.Dialect.Postgres}

  @doc "The dialect for `repo`: the configured one, else the one for its adapter."
  @spec for_repo(module()) :: module()
  def for_repo(repo) do
    case Application.get_env(:vicander, :dialect) do
      nil -> from_adapter(repo)
      dialect -> dialect
    end
  end

  defp from_adapter(repo) do
    adapter = repo.__adapter__()

    case @adapters do
      %{^adapter => dialect} ->
        dialect

      _ ->
        raise ArgumentError,
              "vicander has no dialect for #{inspect(adapter)} (repo #{inspect(repo)}). " <>
                "Supported: #{@adapters |> Map.keys() |> Enum.map_join(", ", &inspect/1)}. " <>
                "Implement the DDD.Dialect behaviour and set `config :vicander, dialect: MyDialect`."
    end
  end

  @doc false
  # A DateTime with microsecond precision, which is what the `:utc_datetime_usec` columns need.
  @spec usec(DateTime.t()) :: DateTime.t()
  def usec(%DateTime{microsecond: {value, _}} = datetime),
    do: %{datetime | microsecond: {value, 6}}
end
