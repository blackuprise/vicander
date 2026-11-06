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

  # ── Batched writes ─────────────────────────────────────────────────────────
  # What a unit of work (`DDD.UnitOfWork`) needs to write many aggregates of one schema in a few
  # statements. Optional: a dialect without them still works, one aggregate at a time. `rows`
  # hold cast (not dumped) values; each callback returns the keys (`to_string` of the primary
  # key) of the rows it actually wrote, so the caller can tell which ones lost a race.

  @doc """
  Insert `rows` (maps of field => value, primary key included) that do not exist yet. A row
  whose key exists is skipped, not an error. Returns the keys that were inserted.
  """
  @callback insert_new(repo :: module(), schema :: module(), pk :: atom(), rows :: [map()]) ::
              [String.t()]

  @doc """
  Update the columns in `set_fields` of each row, but only where the stored version is still
  `expected` (a missing version counts as 0), and advance the version by one. A row is
  `%{id: primary_key, expected: version, values: %{field => value}}`. Returns the keys updated.
  """
  @callback update_versioned(
              repo :: module(),
              schema :: module(),
              pk :: atom(),
              set_fields :: [atom()],
              rows :: [map()]
            ) :: [String.t()]

  @doc """
  Delete each row (`%{id: primary_key, expected: version}`) whose stored version is still
  `expected`. Returns the keys deleted.
  """
  @callback delete_versioned(
              repo :: module(),
              schema :: module(),
              pk :: atom(),
              rows :: [map()]
            ) :: [String.t()]

  @doc """
  True when `exception` is the database aborting a transaction that would very likely succeed
  if it were run again: a deadlock, or a serialization failure. A unit of work reports it as
  `:deadlock_detected`, which `retry_on_conflict` retries.
  """
  @callback retryable?(exception :: Exception.t()) :: boolean()

  @doc """
  When `exception` is the database refusing a write because it breaks a constraint (a unique
  index, a foreign key, a check, a NOT NULL), a map with the `:kind` (`:unique`, `:foreign_key`,
  `:check`, `:not_null`), the `:constraint` name (or nil) and the database's `:detail` (or nil).
  Anything else: `nil`.
  """
  @callback integrity_violation(exception :: Exception.t()) ::
              %{kind: atom(), constraint: String.t() | nil, detail: String.t() | nil} | nil

  @optional_callbacks insert_new: 4,
                      update_versioned: 5,
                      delete_versioned: 4,
                      retryable?: 1,
                      integrity_violation: 1

  @doc """
  The constraint `exception` broke (see the dialect's `integrity_violation/1`), judged by the
  dialect of `repo`, or `nil`.
  """
  @spec integrity_violation(module(), Exception.t()) :: map() | nil
  def integrity_violation(repo, exception) do
    dialect = for_repo(repo)

    if Code.ensure_loaded?(dialect) and function_exported?(dialect, :integrity_violation, 1),
      do: dialect.integrity_violation(exception)
  rescue
    ArgumentError -> nil
  end

  @doc """
  True when `exception` is a retryable abort of a transaction (see the dialect's `retryable?/1`),
  judged by the dialect of `repo`. A dialect that cannot tell says no.
  """
  @spec retryable?(module(), Exception.t()) :: boolean()
  def retryable?(repo, exception) do
    dialect = for_repo(repo)

    Code.ensure_loaded?(dialect) and function_exported?(dialect, :retryable?, 1) and
      dialect.retryable?(exception)
  rescue
    # A repo with no dialect (an adapter we do not know) cannot say.
    ArgumentError -> false
  end

  @doc "True when `dialect` can write a unit of work in batched statements."
  @spec batch?(module()) :: boolean()
  def batch?(dialect) do
    Code.ensure_loaded?(dialect) and function_exported?(dialect, :insert_new, 4) and
      function_exported?(dialect, :update_versioned, 5) and
      function_exported?(dialect, :delete_versioned, 4)
  end

  @adapters %{
    Ecto.Adapters.Postgres => DDD.Dialect.Postgres,
    Ecto.Adapters.MyXQL => DDD.Dialect.MyXQL
  }

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
