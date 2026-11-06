defmodule DDD.Dialect.MyXQL do
  @moduledoc """
  `DDD.Dialect` for `Ecto.Adapters.MyXQL` (MySQL 8).

  MySQL differs from Postgres where the unit of work cares:

    * there is no `UPDATE ... FROM` and no `RETURNING`, and `UPDATE` reports the rows it
      *changed*, not the ones it matched. A batched update therefore first locks the rows it
      means to write and reads their versions (`SELECT ... ORDER BY key FOR UPDATE`), works out
      exactly which still have the version they were loaded at, and writes those. The lock is
      taken in key order, so two units of work on the same rows cannot deadlock each other.
    * a statement that fails (a duplicate key) is undone on its own and the transaction stays
      usable, so a batched insert that hits an existing key finds out which ones exist and
      inserts the rest.
    * `READ ONLY` is chosen when a transaction starts, so `read_only/2` sets it on a pinned
      connection before opening one. Inside a transaction that is already open (a test's, for
      one) MySQL cannot change it, and the function runs without the guarantee.
    * array columns do not exist: use `:map` or a list of value objects (a JSON column).
  """
  @behaviour DDD.Dialect
  require Ecto.Query

  # Per statement MySQL binds at most 65_535 placeholders.
  @max_params 60_000

  @impl true
  def lock_for_claim(query), do: Ecto.Query.lock(query, "FOR UPDATE SKIP LOCKED")

  @impl true
  def now(repo) do
    %{rows: [[naive]]} = repo.query!("SELECT UTC_TIMESTAMP(6)")
    naive |> DateTime.from_naive!("Etc/UTC") |> DDD.Dialect.usec()
  end

  @impl true
  def read_only(repo, fun) do
    if repo.in_transaction?() do
      fun.()
    else
      repo.checkout(fn -> read_only_transaction(repo, fun) end)
    end
  end

  defp read_only_transaction(repo, fun) do
    repo.query!("SET TRANSACTION READ ONLY")

    {:error, {:query_result, result}} =
      repo.transaction(fn -> repo.rollback({:query_result, fun.()}) end)

    result
  rescue
    # ER_CANT_CHANGE_TX_CHARACTERISTICS: "Transaction characteristics can't be changed while a
    # transaction is in progress". The connection is already in one, so run without the lock.
    error -> if mysql_code(error) == 1568, do: fun.(), else: reraise(error, __STACKTRACE__)
  end

  @impl true
  def columns(repo, table) do
    %{rows: rows} = repo.query!("SHOW COLUMNS FROM #{quote_name(table)}")
    Enum.map(rows, &hd/1)
  rescue
    # ER_NO_SUCH_TABLE: a table that is not there has no columns.
    error -> if mysql_code(error) == 1146, do: [], else: reraise(error, __STACKTRACE__)
  end

  # 1213: deadlock found when trying to get lock; try restarting transaction.
  @impl true
  def retryable?(error), do: mysql_code(error) == 1213

  # ── Batched writes ─────────────────────────────────────────────────────────

  @impl true
  def insert_new(repo, schema, pk, rows) do
    columns = rows |> Enum.map(&map_size/1) |> Enum.max()

    rows
    |> Enum.chunk_every(max(div(@max_params, columns), 1))
    |> Enum.flat_map(&insert_chunk(repo, schema, pk, &1))
  end

  # One plain INSERT. If a key exists the statement is undone as a whole (and only it), so the
  # keys that exist are looked up and the others inserted.
  defp insert_chunk(repo, schema, pk, rows) do
    repo.insert_all(schema, rows)
    Enum.map(rows, &(&1 |> Map.fetch!(pk) |> to_string()))
  rescue
    error ->
      if primary_key_duplicate?(error) do
        existing = existing_keys(repo, schema, pk, Enum.map(rows, &Map.fetch!(&1, pk)))
        fresh = Enum.reject(rows, &(to_string(Map.fetch!(&1, pk)) in existing))
        if fresh == [], do: [], else: insert_chunk_once(repo, schema, pk, fresh)
      else
        reraise error, __STACKTRACE__
      end
  end

  # The retry after a duplicate: if a key turned up meanwhile, nothing of this chunk is written.
  defp insert_chunk_once(repo, schema, pk, rows) do
    repo.insert_all(schema, rows)
    Enum.map(rows, &(&1 |> Map.fetch!(pk) |> to_string()))
  rescue
    error -> if primary_key_duplicate?(error), do: [], else: reraise(error, __STACKTRACE__)
  end

  # 1062 names the index in its message: "Duplicate entry 'x' for key 'table.PRIMARY'". Another
  # unique index is not "the row exists", it is an error to report.
  defp primary_key_duplicate?(error),
    do: mysql_code(error) == 1062 and Exception.message(error) =~ ~r/PRIMARY'/

  @violations %{1062 => :unique, 1451 => :foreign_key, 1452 => :foreign_key, 1048 => :not_null}

  @impl true
  def integrity_violation(error) do
    code = mysql_code(error)

    cond do
      is_map_key(@violations, code) ->
        message = Exception.message(error)

        %{
          kind: Map.fetch!(@violations, code),
          constraint: constraint_name(message),
          detail: message
        }

      # 3819: a CHECK constraint is violated.
      code == 3819 ->
        %{
          kind: :check,
          constraint: constraint_name(Exception.message(error)),
          detail: Exception.message(error)
        }

      true ->
        nil
    end
  end

  defp constraint_name(message) do
    case Regex.run(~r/(?:for key|constraint) '([^']+)'/, message) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp existing_keys(repo, schema, pk, ids) do
    import Ecto.Query

    from(r in schema, where: field(r, ^pk) in ^ids, select: field(r, ^pk))
    |> repo.all()
    |> MapSet.new(&to_string/1)
  end

  # UPDATE t AS t INNER JOIN (SELECT ? AS k, ? AS ev, ? AS c0 UNION ALL SELECT ?, ?, ?) AS v
  #     ON t.pk = v.k AND COALESCE(t.version, 0) = v.ev
  #    SET t.c = v.c0, ..., t.version = v.ev + 1
  @impl true
  def update_versioned(repo, schema, pk, set_fields, rows) do
    table = quote_name(schema.__schema__(:source))
    pk_col = column(schema, pk)
    per_row = 2 + length(set_fields)
    cells = [placeholder(schema, pk), "?" | Enum.map(set_fields, &placeholder(schema, &1))]

    sets =
      set_fields
      |> Enum.with_index()
      |> Enum.map(fn {field, i} -> "t.#{quote_name(column(schema, field))} = v.c#{i}" end)
      |> Kernel.++(["t.`version` = v.ev + 1"])
      |> Enum.join(", ")

    rows
    |> Enum.chunk_every(max(div(@max_params, per_row), 1))
    |> Enum.flat_map(fn chunk ->
      matching = lock_matching(repo, schema, pk, chunk)

      if matching == [] do
        []
      else
        params =
          Enum.flat_map(matching, fn row ->
            [
              dump(schema, pk, row.id),
              row.expected | Enum.map(set_fields, &dump(schema, &1, row.values[&1]))
            ]
          end)

        selects = derived_selects(length(matching), cells)

        repo.query!(
          "UPDATE #{table} AS t INNER JOIN (#{selects}) AS v " <>
            "ON t.#{quote_name(pk_col)} = v.k AND COALESCE(t.`version`, 0) = v.ev SET #{sets}",
          params
        )

        Enum.map(matching, &to_string(&1.id))
      end
    end)
  end

  @impl true
  def delete_versioned(repo, schema, pk, rows) do
    table = quote_name(schema.__schema__(:source))
    pk_col = column(schema, pk)

    rows
    |> Enum.chunk_every(@max_params)
    |> Enum.flat_map(fn chunk ->
      matching = lock_matching(repo, schema, pk, chunk)

      if matching == [] do
        []
      else
        marks = Enum.map_join(matching, ", ", fn _ -> "?" end)

        repo.query!(
          "DELETE FROM #{table} WHERE #{quote_name(pk_col)} IN (#{marks})",
          Enum.map(matching, &dump(schema, pk, &1.id))
        )

        Enum.map(matching, &to_string(&1.id))
      end
    end)
  end

  # Lock the rows (in key order) and keep the ones whose stored version is the expected one.
  # Rows that are gone, or that someone else changed, are left out.
  defp lock_matching(repo, schema, pk, rows) do
    import Ecto.Query

    ids = Enum.map(rows, & &1.id)

    stored =
      from(r in schema,
        where: field(r, ^pk) in ^ids,
        order_by: field(r, ^pk),
        select: {field(r, ^pk), r.version},
        lock: "FOR UPDATE"
      )
      |> repo.all()
      |> Map.new(fn {id, version} -> {to_string(id), version || 0} end)

    Enum.filter(rows, &(Map.get(stored, to_string(&1.id)) == &1.expected))
  end

  # SELECT ? AS k, ? AS ev, ? AS c0 UNION ALL SELECT ?, ?, ? ...   (`cells`: a placeholder per column)
  defp derived_selects(row_count, cells) do
    first =
      cells
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {cell, i} -> "#{cell} AS #{alias_name(i)}" end)

    rest = String.duplicate(" UNION ALL SELECT #{Enum.join(cells, ", ")}", row_count - 1)
    "SELECT #{first}#{rest}"
  end

  defp alias_name(0), do: "k"
  defp alias_name(1), do: "ev"
  defp alias_name(n), do: "c#{n - 2}"

  # A binary value (a uuid key, a blob) sent as a parameter of a derived table would be read as
  # text, and rejected when it is not valid UTF-8: say that it is binary.
  defp placeholder(schema, field) do
    if schema.__schema__(:type, field) in [:binary, :binary_id, Ecto.UUID],
      do: "CAST(? AS BINARY)",
      else: "?"
  end

  defp dump(schema, field, value) do
    {:ok, dumped} =
      Ecto.Type.adapter_dump(Ecto.Adapters.MyXQL, schema.__schema__(:type, field), value)

    dumped
  end

  defp column(schema, field), do: schema.__schema__(:field_source, field) |> Atom.to_string()
  defp quote_name(name), do: "`" <> String.replace(name, "`", "``") <> "`"

  # The MySQL error number of a `MyXQL.Error`, or nil for anything else. Matched by shape so
  # that this module compiles without the driver.
  defp mysql_code(%{__struct__: MyXQL.Error, mysql: %{code: code}}), do: code
  defp mysql_code(_other), do: nil
end
