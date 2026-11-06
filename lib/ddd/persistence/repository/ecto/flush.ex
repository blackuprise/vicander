defmodule DDD.Repository.Ecto.Flush do
  @moduledoc false
  # Writes what a unit of work collected for one Ecto repository adapter in a few statements:
  #
  #   1. one INSERT for the new aggregates (a key that exists is a conflict, not an error),
  #   2. one UPDATE ... FROM (VALUES ...) for the changed ones, each guarded by the version it
  #      was loaded at,
  #   3. one SELECT to check the version of aggregates that only emitted events,
  #   4. one DELETE ... USING (VALUES ...) for the removed ones, guarded the same way,
  #   5. one INSERT of all their events into the outbox.
  #
  # A row that was not written lost a race; they are reported together as one
  # `:stale_aggregate`. The caller's transaction rolls everything back.

  import Ecto.Query, only: [from: 2]

  alias DDD.Repository.Ecto, as: Adapter

  # Events carry 9 columns; 60_000 stays under the 65_535 parameters one statement may bind.
  @event_chunk div(60_000, 9)

  @type change :: %{
          op: :insert | :update | :check | :delete,
          aggregate: struct(),
          expected: non_neg_integer(),
          events: [struct()]
        }

  @zero %{inserted: 0, updated: 0, checked: 0, deleted: 0, events: 0, statements: 0}

  @doc """
  Write `changes`. `ctx` has the adapter's `repo`, `schema`, `aggregate` module, `pk` field and the
  `from_domain` and `cast` functions of the adapter. Returns `{:ok, stats}`, `{:error, error}`, or
  `:unsupported` when the repo's dialect has no batched writes.
  """
  def run(ctx, changes, opts \\ []) do
    dialect = DDD.Dialect.for_repo(ctx.repo)

    if DDD.Dialect.batch?(dialect) do
      with {:ok, prepared} <- prepare(ctx, changes) do
        if Keyword.get(opts, :sorted, false),
          do: write(ctx, dialect, Enum.sort_by(prepared, & &1.key), true),
          else: write(ctx, dialect, prepared, false)
      end
    else
      :unsupported
    end
  end

  # ── Preparing ─────────────────────────────────────────────────────────────

  defp prepare(ctx, changes) do
    changes
    |> Enum.reduce_while({:ok, []}, fn change, {:ok, acc} ->
      case prepare_one(ctx, change) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp prepare_one(ctx, %{op: op} = change) when op in [:check, :delete] do
    {:ok, base(ctx, change, %{})}
  end

  defp prepare_one(ctx, change) do
    params = ctx.from_domain.(change.aggregate)
    changeset = ctx.cast.(struct(ctx.schema), params)

    if changeset.valid? do
      applied = Ecto.Changeset.apply_changes(changeset)
      fields = ctx.schema.__schema__(:fields)

      set =
        for field <- Map.keys(params), field in fields, field not in [ctx.pk, :version], do: field

      {:ok, base(ctx, change, Map.new(set, &{&1, Map.get(applied, &1)}))}
    else
      {:error,
       DDD.Error.infrastructure(
         entity: ctx.aggregate,
         entity_id: key(change.aggregate),
         operation: :save,
         code: :persistence_failed,
         message: "could not save #{inspect(ctx.aggregate)}",
         details: %{errors: changeset.errors}
       )}
    end
  end

  defp base(ctx, change, values) do
    key = key(change.aggregate)

    {:ok, pk_value} = Ecto.Type.cast(ctx.schema.__schema__(:type, ctx.pk), key)

    %{
      op: change.op,
      key: key,
      pk_value: pk_value,
      expected: change.expected,
      values: values,
      events: change.events,
      aggregate: change.aggregate
    }
  end

  defp key(aggregate), do: aggregate |> DDD.Identity.key() |> to_string()

  # ── Writing ───────────────────────────────────────────────────────────────

  defp write(ctx, dialect, prepared, lock?) do
    by_op = Enum.group_by(prepared, & &1.op)
    stats = if lock?, do: lock_rows(ctx, prepared), else: @zero

    with {:ok, stats} <- insert(ctx, dialect, Map.get(by_op, :insert, []), stats),
         {:ok, stats} <- update(ctx, dialect, Map.get(by_op, :update, []), stats),
         {:ok, stats} <- check(ctx, Map.get(by_op, :check, []), stats),
         {:ok, stats} <- delete(ctx, dialect, Map.get(by_op, :delete, []), stats) do
      insert_events(ctx, prepared, stats)
    end
  end

  # `flush_order: :sorted`: take the locks on the rows that will change (and be checked, or
  # deleted) in key order before writing any of them. A statement with many rows locks them in
  # whatever order its plan visits them, so two such statements can wait for each other; locks
  # taken in one and the same order cannot.
  defp lock_rows(ctx, prepared) do
    ids = for p <- prepared, p.op in [:update, :check, :delete], do: p.pk_value

    if ids == [] do
      @zero
    else
      from(r in ctx.schema,
        where: field(r, ^ctx.pk) in ^ids,
        order_by: field(r, ^ctx.pk),
        select: field(r, ^ctx.pk),
        lock: "FOR UPDATE"
      )
      |> ctx.repo.all()

      %{@zero | statements: 1}
    end
  end

  defp insert(_ctx, _dialect, [], stats), do: {:ok, stats}

  defp insert(ctx, dialect, inserts, stats) do
    rows =
      Enum.map(inserts, fn p ->
        p.values |> Map.put(ctx.pk, p.pk_value) |> Map.put(:version, 1)
      end)

    inserted = MapSet.new(dialect.insert_new(ctx.repo, ctx.schema, ctx.pk, rows))
    lost = Enum.reject(inserts, &MapSet.member?(inserted, &1.key))

    finish(ctx, lost, bump(stats, :inserted, length(inserts) - length(lost), 1))
  end

  defp update(_ctx, _dialect, [], stats), do: {:ok, stats}

  # One statement per set of columns. That is one statement unless `from_domain` gives some
  # aggregates different columns than others, which a statement cannot express.
  defp update(ctx, dialect, updates, stats) do
    updates
    |> Enum.group_by(&(&1.values |> Map.keys() |> Enum.sort()))
    |> Enum.reduce_while({:ok, stats}, fn {set_fields, group}, {:ok, stats} ->
      rows = Enum.map(group, &%{id: &1.pk_value, expected: &1.expected, values: &1.values})

      updated =
        MapSet.new(dialect.update_versioned(ctx.repo, ctx.schema, ctx.pk, set_fields, rows))

      lost = Enum.reject(group, &MapSet.member?(updated, &1.key))

      case finish(ctx, lost, bump(stats, :updated, length(group) - length(lost), 1)) do
        {:ok, _} = ok -> {:cont, ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check(_ctx, [], stats), do: {:ok, stats}

  defp check(ctx, checks, stats) do
    # Locked (shared, in key order): the events that follow were decided on this version, so no
    # one may change the row before we commit.
    stored = stored_versions(ctx, checks, true)
    lost = Enum.reject(checks, &(Map.get(stored, &1.key) == &1.expected))

    finish(ctx, lost, bump(stats, :checked, length(checks) - length(lost), 1), stored)
  end

  defp delete(_ctx, _dialect, [], stats), do: {:ok, stats}

  defp delete(ctx, dialect, deletes, stats) do
    rows = Enum.map(deletes, &%{id: &1.pk_value, expected: &1.expected})

    deleted = MapSet.new(dialect.delete_versioned(ctx.repo, ctx.schema, ctx.pk, rows))
    lost = Enum.reject(deletes, &MapSet.member?(deleted, &1.key))

    finish(ctx, lost, bump(stats, :deleted, length(deletes) - length(lost), 1))
  end

  defp insert_events(ctx, prepared, stats) do
    inserted_at = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    rows =
      for p <- prepared, event <- p.events do
        Adapter.event_row(ctx.aggregate, p.key, event, inserted_at)
      end

    if rows == [] do
      {:ok, stats}
    else
      rows
      |> Enum.chunk_every(@event_chunk)
      |> Enum.each(&ctx.repo.insert_all(DDD.Outbox.Event, &1))

      statements = div(length(rows) - 1, @event_chunk) + 1

      {:ok,
       %{stats | events: stats.events + length(rows), statements: stats.statements + statements}}
    end
  end

  defp bump(stats, field, count, statements) do
    %{
      stats
      | field => Map.fetch!(stats, field) + count,
        statements: stats.statements + statements
    }
  end

  # ── Conflicts ─────────────────────────────────────────────────────────────

  defp finish(ctx, lost, stats, stored \\ nil)
  defp finish(_ctx, [], stats, _stored), do: {:ok, stats}

  defp finish(ctx, lost, _stats, stored),
    do: {:error, stale(ctx, lost, stored || stored_versions(ctx, lost))}

  # The stored version of each of `items` (a missing row has none).
  defp stored_versions(ctx, items, lock \\ nil) do
    ids = Enum.map(items, & &1.pk_value)

    query =
      from(r in ctx.schema,
        where: field(r, ^ctx.pk) in ^ids,
        order_by: field(r, ^ctx.pk),
        select: {field(r, ^ctx.pk), r.version}
      )

    query = if lock, do: Ecto.Query.lock(query, "FOR SHARE"), else: query

    ctx.repo.all(query)
    |> Map.new(fn {id, version} -> {to_string(id), version || 0} end)
  end

  # One `:stale_aggregate` for everything that lost. The first conflict fills the usual fields,
  # so code that reads `details.actual_version` keeps working; all of them are in `conflicts`.
  defp stale(ctx, lost, stored) do
    conflicts =
      Enum.map(lost, fn p ->
        %{id: p.key, expected_version: p.expected, actual_version: Map.get(stored, p.key)}
      end)

    [first | _] =
      Enum.map(conflicts, fn c ->
        Adapter.stale_error(ctx.aggregate, c.id, c.expected_version, c.actual_version)
      end)

    %{first | details: Map.put(first.details, :conflicts, conflicts)}
  end
end
