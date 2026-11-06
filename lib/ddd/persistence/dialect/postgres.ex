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

  # A deadlock, or a serialization failure at a stricter isolation level: running the transaction
  # again usually works.
  @impl true
  def retryable?(%{__struct__: Postgrex.Error, postgres: %{code: code}}),
    do: code in [:deadlock_detected, :serialization_failure]

  def retryable?(_exception), do: false

  @violations %{
    unique_violation: :unique,
    foreign_key_violation: :foreign_key,
    check_violation: :check,
    not_null_violation: :not_null
  }

  @impl true
  def integrity_violation(%{__struct__: Postgrex.Error, postgres: %{code: code} = pg})
      when is_map_key(@violations, code) do
    %{
      kind: Map.fetch!(@violations, code),
      constraint: Map.get(pg, :constraint),
      detail: Map.get(pg, :detail) || Map.get(pg, :message)
    }
  end

  def integrity_violation(_exception), do: nil

  # ── Batched writes ─────────────────────────────────────────────────────────

  # Postgres allows 65_535 parameters in one statement.
  @max_params 60_000

  @impl true
  def insert_new(repo, schema, pk, rows) do
    columns = rows |> Enum.map(&map_size/1) |> Enum.max()

    rows
    |> Enum.chunk_every(max(div(@max_params, columns), 1))
    |> Enum.flat_map(fn chunk ->
      # Only a row with an existing *key* is skipped. Breaking another unique index is an error.
      {_count, inserted} =
        repo.insert_all(schema, chunk,
          on_conflict: :nothing,
          conflict_target: [pk],
          returning: [pk]
        )

      Enum.map(inserted, &(&1 |> Map.fetch!(pk) |> to_string()))
    end)
  end

  # UPDATE t SET c = v.c0, ..., version = v.ev + 1
  #   FROM (VALUES ($1::uuid, $2::bigint, ...), ...) AS v(k, ev, c0, ...)
  #  WHERE t.pk = v.k AND COALESCE(t.version, 0) = v.ev
  # RETURNING t.pk
  #
  # The parameter types come from the table itself, so every column type (enums, arrays, jsonb,
  # numeric) casts as the database defines it.
  @impl true
  def update_versioned(repo, schema, pk, set_fields, rows) do
    types = column_types(repo, schema.__schema__(:source))
    table = quote_name(schema.__schema__(:source))
    pk_col = column(schema, pk)
    per_row = 2 + length(set_fields)

    sets =
      set_fields
      |> Enum.with_index()
      |> Enum.map(fn {field, i} -> "#{quote_name(column(schema, field))} = v.c#{i}" end)
      |> Kernel.++([~s("version" = v.ev + 1)])
      |> Enum.join(", ")

    aliases = Enum.join(["k", "ev" | Enum.map(0..(length(set_fields) - 1)//1, &"c#{&1}")], ", ")

    value_types =
      [
        Map.fetch!(types, pk_col),
        "bigint" | Enum.map(set_fields, &Map.fetch!(types, column(schema, &1)))
      ]

    rows
    |> Enum.chunk_every(max(div(@max_params, per_row), 1))
    |> Enum.flat_map(fn chunk ->
      params =
        Enum.flat_map(chunk, fn row ->
          [
            dump(schema, pk, row.id),
            row.expected | Enum.map(set_fields, &dump(schema, &1, row.values[&1]))
          ]
        end)

      sql =
        "UPDATE #{table} AS t SET #{sets} FROM (VALUES #{values_sql(length(chunk), value_types)}) " <>
          "AS v(#{aliases}) WHERE t.#{quote_name(pk_col)} = v.k AND COALESCE(t.\"version\", 0) = v.ev " <>
          "RETURNING t.#{quote_name(pk_col)}"

      returned_keys(repo, schema, pk, sql, params)
    end)
  end

  @impl true
  def delete_versioned(repo, schema, pk, rows) do
    types = column_types(repo, schema.__schema__(:source))
    table = quote_name(schema.__schema__(:source))
    pk_col = column(schema, pk)
    value_types = [Map.fetch!(types, pk_col), "bigint"]

    rows
    |> Enum.chunk_every(div(@max_params, 2))
    |> Enum.flat_map(fn chunk ->
      params = Enum.flat_map(chunk, &[dump(schema, pk, &1.id), &1.expected])

      sql =
        "DELETE FROM #{table} AS t USING (VALUES #{values_sql(length(chunk), value_types)}) " <>
          "AS v(k, ev) WHERE t.#{quote_name(pk_col)} = v.k AND COALESCE(t.\"version\", 0) = v.ev " <>
          "RETURNING t.#{quote_name(pk_col)}"

      returned_keys(repo, schema, pk, sql, params)
    end)
  end

  defp returned_keys(repo, schema, pk, sql, params) do
    %{rows: rows} = repo.query!(sql, params)
    type = schema.__schema__(:type, pk)

    Enum.map(rows, fn [raw] ->
      {:ok, key} = Ecto.Type.adapter_load(Ecto.Adapters.Postgres, type, raw)
      to_string(key)
    end)
  end

  # ($1::uuid, $2::bigint, $3::text), ($4::uuid, ...), ...
  defp values_sql(row_count, types) do
    width = length(types)

    Enum.map_join(0..(row_count - 1), ", ", fn r ->
      cells =
        types
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {type, c} -> "$#{r * width + c}::#{type}" end)

      "(#{cells})"
    end)
  end

  defp dump(schema, field, value) do
    {:ok, dumped} =
      Ecto.Type.adapter_dump(Ecto.Adapters.Postgres, schema.__schema__(:type, field), value)

    dumped
  end

  defp column(schema, field), do: schema.__schema__(:field_source, field) |> Atom.to_string()
  defp quote_name(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

  # The SQL type of each column, as the database spells it. Read once per table and kept: a
  # table's column types do not change while the application runs (see `clear_cache/0`).
  defp column_types(repo, table) do
    key = {__MODULE__, :column_types, repo, table}

    case :persistent_term.get(key, nil) do
      nil ->
        %{rows: rows} =
          repo.query!(
            """
            SELECT a.attname, format_type(a.atttypid, a.atttypmod)
              FROM pg_attribute a
             WHERE a.attrelid = $1::text::regclass AND a.attnum > 0 AND NOT a.attisdropped
            """,
            [quote_name(table)]
          )

        types = Map.new(rows, fn [name, type] -> {name, type} end)
        :persistent_term.put(key, types)
        types

      types ->
        types
    end
  end

  @doc "Forget the column types read so far (after a migration changes a table)."
  def clear_cache do
    for {{__MODULE__, :column_types, _, _} = key, _} <- :persistent_term.get(),
        do: :persistent_term.erase(key)

    :ok
  end
end
