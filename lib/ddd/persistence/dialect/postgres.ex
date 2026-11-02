defmodule DDD.Dialect.Postgres do
  @moduledoc "`DDD.Dialect` for `Ecto.Adapters.Postgres`."
  @behaviour DDD.Dialect
  require Ecto.Query

  @impl true
  def lock_for_claim(query), do: Ecto.Query.lock(query, "FOR UPDATE SKIP LOCKED")

  @impl true
  def now(repo) do
    %{rows: [[naive]]} = repo.query!("SELECT now() AT TIME ZONE 'UTC'")
    naive |> DateTime.from_naive!("Etc/UTC") |> DDD.Dialect.usec()
  end

  # The transaction is always rolled back: a query has nothing to commit, and a rollback also
  # undoes `SET LOCAL`, so the read-only mode never leaks into a surrounding (test) transaction.
  @impl true
  def read_only(repo, fun) do
    if repo.in_transaction?() do
      fun.()
    else
      {:error, {:query_result, result}} =
        repo.transaction(fn ->
          repo.query!("SET LOCAL transaction_read_only = on")
          repo.rollback({:query_result, fun.()})
        end)

      result
    end
  end

  @impl true
  def columns(repo, table) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT column_name FROM information_schema.columns
         WHERE table_name = $1 AND table_schema = ANY (current_schemas(false))
        """,
        [table]
      )

    List.flatten(rows)
  end
end
