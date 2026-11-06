defmodule DDD.UnitOfWork do
  @moduledoc """
  Remembers what a command loaded and saved, and writes the changes once, at the end.

  A command (and a transactional event handler) runs inside a unit of work. Inside it, the
  repositories behave differently from how they do outside one:

    * **`find_by_id`** loads an aggregate once. Asking for the same id again returns the same
      aggregate without a query, including one the command has just saved (with its new
      version), and `{:error, :not_found}` for one it has deleted.
    * **`save`** and **`delete`** write nothing yet. They record the change and return at once.
      `save` returns the aggregate with the version it will have once written (the loaded
      version plus one; `1` for a new aggregate).
    * **Everything is written when the outermost command ends**, just before its transaction
      commits. Only aggregates that changed (or emitted events) are written. If a write fails,
      the command returns that error and the transaction rolls back. A version conflict fails
      the command with `:stale_aggregate`, exactly as a failed `save` did, so
      `retry_on_conflict` works as before.
    * **There is no `flush`.** A command that needs its writes before it can go on is doing two
      jobs: split it into two commands.

  ## What raises

  Reading by anything other than the id (`find_by_*`, `list`, `page`, `slice`, `count`) goes
  to the database, which does not have this command's unwritten changes yet. After the command
  has saved or deleted something, such a read raises `DDD.UnitOfWork.PendingChangesError`
  instead of returning an answer that is quietly wrong. Run the query before the first `save`,
  or in another command.

  Code that bypasses the repositories (`Repo.query!`, `Repo.all` on your own schema) cannot be
  detected: it reads the database and does not see unwritten changes.

  ## Outside a unit of work

  Nothing changes. `save` and `delete` write at once, `find_by_id` always reads the database.

  ## Opting out

  `use DDD.Command, unit_of_work: false` runs a command without one.

  `run/1` opens one around any code that has no command around it:

      DDD.UnitOfWork.run(fn ->
        with {:ok, order} <- Orders.find_by_id(id),
             {:ok, order} <- Order.ship(order),
             {:ok, _} <- Orders.save(order),
             do: {:ok, order}
      end)

  A command or `run/1` called inside an open unit of work joins it and writes nothing itself;
  the outermost one writes.
  """

  alias DDD.Repository.Ecto, as: EctoAdapter

  @key {__MODULE__, :state}

  defmodule PendingChangesError do
    @moduledoc "Raised by a repository query that cannot see this unit of work's unwritten changes."
    defexception [:message]
  end

  # ── Running ───────────────────────────────────────────────────────────────

  @doc """
  Run `fun` in a unit of work and write its changes when it returns `{:ok, _}`.

  Returns `fun`'s result, or `{:error, error}` when the writes fail. Joins a unit of work that
  is already open (and then writes nothing: the outermost one does).

  ## Options

    * `:flush_order` — `:registration` (default) writes in the order the changes were first
      recorded; `:sorted` writes the tables in name order and the rows of each in key order, and
      locks the rows it is going to change in key order first. Units of work that all do so
      cannot deadlock each other. It costs one more statement per repository. A unit of work
      that joins another and asks for `:sorted` makes the whole of it sorted.
  """
  @spec run((-> result), keyword()) :: result | {:error, term()} when result: term()
  def run(fun, opts \\ []) do
    case execute(fun, &match?({:ok, _}, &1), opts) do
      {:ok, result} -> result
      {:flush_failed, error} -> {:error, error}
    end
  end

  @doc false
  # `{:ok, result}` once the changes are written (or when there was nothing to write, or
  # `commit?` said not to), `{:flush_failed, error}` when a write failed. `commit?` receives the
  # result of `fun` and decides whether the changes are kept: the default keeps them for
  # `{:ok, _}`.
  @spec execute((-> result), (result -> boolean()), keyword()) ::
          {:ok, result} | {:flush_failed, term()}
        when result: term()
  def execute(fun, commit? \\ &match?({:ok, _}, &1), opts \\ []) do
    sorted? = Keyword.get(opts, :flush_order, :registration) == :sorted

    if open?() do
      if sorted?, do: Process.put(@key, %{Process.get(@key) | sorted: true})
      {:ok, fun.()}
    else
      Process.put(@key, new_state(sorted?))

      try do
        result = fun.()

        if commit?.(result) do
          case flush() do
            :ok -> {:ok, result}
            {:error, error} -> {:flush_failed, error}
          end
        else
          {:ok, result}
        end
      after
        Process.delete(@key)
      end
    end
  end

  @doc "True while a unit of work is open in this process."
  @spec open?() :: boolean()
  def open?, do: Process.get(@key) != nil

  @doc "True when the open unit of work has changes it has not written yet."
  @spec pending?() :: boolean()
  def pending? do
    case Process.get(@key) do
      nil -> false
      state -> state.order != []
    end
  end

  @doc """
  What the open unit of work has done so far: `%{loaded: n, hits: n, saved: n, deleted: n}`,
  or `nil` outside one. `hits` counts the `find_by_id` calls answered without a query.
  """
  @spec stats() :: map() | nil
  def stats do
    case Process.get(@key) do
      nil ->
        nil

      state ->
        ops = for {_, %{op: op}} <- state.entries, op != nil, do: op

        %{
          loaded: state.loaded,
          hits: state.hits,
          saved: count(ops, :save),
          deleted: count(ops, :delete)
        }
    end
  end

  defp count(ops, op), do: Enum.count(ops, &(&1 == op))

  # ── Called by the repository adapters ─────────────────────────────────────

  @doc false
  # `find_by_id`: from the identity map when the unit of work has the aggregate, else `loader`.
  def read(adapter, id, loader) do
    case Process.get(@key) do
      nil ->
        loader.()

      state ->
        key = {adapter, to_string(id)}

        case state.entries do
          %{^key => %{op: :delete}} ->
            {:error, :not_found}

          %{^key => %{current: current}} when current != nil ->
            Process.put(@key, %{state | hits: state.hits + 1})
            {:ok, current}

          _ ->
            case loader.() do
              {:ok, aggregate} = found ->
                entry = %{
                  loaded: aggregate,
                  current: aggregate,
                  base: version(aggregate),
                  events: [],
                  op: nil
                }

                put_entry(state, key, entry, loaded: 1)
                found

              other ->
                other
            end
        end
    end
  end

  @doc false
  # Load the aggregates with these ids into the open unit of work with one query, so that
  # `find_by_id` answers for them without another. Returns the ids that do not exist. Ids the
  # unit of work already holds are not read again.
  def preload(adapter, ids) do
    ids = ids |> Enum.map(&to_string/1) |> Enum.uniq()
    state = Process.get(@key)
    wanted = Enum.reject(ids, &Map.has_key?(state.entries, {adapter, &1}))
    loaded = if wanted == [], do: [], else: adapter.__load_many__(wanted)

    for aggregate <- loaded do
      entry = %{
        loaded: aggregate,
        current: aggregate,
        base: version(aggregate),
        events: [],
        op: nil
      }

      put_entry(Process.get(@key), {adapter, key_of(aggregate)}, entry, loaded: 1)
    end

    found = MapSet.new(loaded, &key_of/1)
    Enum.reject(wanted, &MapSet.member?(found, &1))
  end

  @doc false
  # `save`: recorded in a unit of work, written by `immediate` outside one.
  def save(adapter, aggregate, immediate) do
    case Process.get(@key) do
      nil -> immediate.(aggregate)
      state -> register_save(state, adapter, aggregate)
    end
  end

  @doc false
  def delete(adapter, aggregate, immediate) do
    case Process.get(@key) do
      nil -> immediate.(aggregate)
      state -> register_delete(state, adapter, aggregate)
    end
  end

  @doc false
  # Called first by every repository read that is not by id.
  def guard_query!(adapter, query) do
    if pending?() do
      raise PendingChangesError,
        message:
          "#{inspect(adapter)}.#{query} reads the database, which does not have this command's " <>
            "unwritten changes yet (it has saved or deleted something already). Run the query " <>
            "before the first save, or in another command."
    end

    :ok
  end

  # ── Recording ─────────────────────────────────────────────────────────────

  defp register_save(state, adapter, aggregate) do
    if DDD.Schema.sealed?(aggregate) do
      key = {adapter, key_of(aggregate)}
      entry = Map.get(state.entries, key)
      given = version(aggregate)

      cond do
        entry && entry.op == :delete ->
          {:error, stale(aggregate, given, nil)}

        entry && given not in [entry.base, entry.base + 1] ->
          {:error, stale(aggregate, given, entry.base + 1)}

        true ->
          base = if entry, do: entry.base, else: given
          {events, clean} = aggregate.__struct__.pop_events(aggregate)

          current =
            clean
            |> Map.put(:version, base + 1)
            |> stamp(entry && entry.loaded, base)
            |> DDD.Schema.seal()

          entry = %{
            loaded: entry && entry.loaded,
            current: current,
            base: base,
            events: ((entry && entry.events) || []) ++ events,
            op: :save
          }

          put_entry(state, key, entry, [])
          {:ok, current}
      end
    else
      {:error, DDD.Schema.unsealed_error(aggregate)}
    end
  end

  defp register_delete(state, adapter, aggregate) do
    key = {adapter, key_of(aggregate)}
    entry = Map.get(state.entries, key)

    # An aggregate created and deleted in the same unit of work never reached the database.
    created_here? = entry != nil and entry.op == :save and entry.loaded == nil and entry.base == 0

    entry = %{
      loaded: entry && entry.loaded,
      current: nil,
      base: if(entry, do: entry.base, else: version(aggregate)),
      events: [],
      op: :delete,
      aggregate: aggregate,
      skip: created_here?
    }

    put_entry(state, key, entry, [])
    :ok
  end

  defp put_entry(state, key, entry, counts) do
    order =
      if entry.op != nil and not Map.has_key?(state.pending, key),
        do: [key | state.order],
        else: state.order

    pending = if entry.op != nil, do: Map.put(state.pending, key, true), else: state.pending

    Process.put(@key, %{
      state
      | entries: Map.put(state.entries, key, entry),
        order: order,
        pending: pending,
        loaded: state.loaded + Keyword.get(counts, :loaded, 0)
    })
  end

  defp new_state(sorted?),
    do: %{entries: %{}, order: [], pending: %{}, loaded: 0, hits: 0, sorted: sorted?}

  defp key_of(aggregate), do: aggregate |> DDD.Identity.key() |> to_string()
  defp version(aggregate), do: Map.get(aggregate, :version) || 0

  defp stale(aggregate, expected, actual),
    do: EctoAdapter.stale_error(aggregate.__struct__, key_of(aggregate), expected, actual)

  # ── Writing ───────────────────────────────────────────────────────────────

  @zero %{inserted: 0, updated: 0, checked: 0, deleted: 0, events: 0, statements: 0, written: 0}

  # The changes go to each repository adapter in the order they were first recorded. An adapter
  # that can write a batch gets all of its changes at once (`__flush__/1`); one that cannot, or
  # whose database cannot, is written an aggregate at a time. It stops at the first failure: the
  # caller's transaction rolls back, so nothing before it stays.
  defp flush do
    state = Process.get(@key)

    case groups(state) do
      [] ->
        :ok

      groups ->
        meta = %{
          adapters: Enum.map(groups, fn {adapter, _entries, _changes} -> adapter end),
          flush_order: if(state.sorted, do: :sorted, else: :registration)
        }

        load = %{loaded: state.loaded, hits: state.hits}

        # `:ok` or `{:error, error}`. The counts are the measurements of the stop event.
        :telemetry.span([:ddd, :unit_of_work, :flush], meta, fn ->
          flush_groups(groups, load, state.sorted, meta)
        end)
    end
  end

  defp flush_groups(groups, load, sorted?, meta) do
    repos = repos(groups)

    case guard(repos, fn ->
           in_transaction(repos, fn -> write_groups(groups, sorted?) end)
         end) do
      {:ok, stats} -> {:ok, Map.merge(stats, load), Map.put(meta, :result, :ok)}
      {:error, _} = error -> {error, Map.merge(@zero, load), Map.put(meta, :result, :error)}
    end
  end

  # `[{adapter, entries, changes}]`: what was recorded, per adapter, in the order it first
  # appeared. `entries` is for an adapter written one at a time, `changes` for a batch. Adapters
  # with nothing to write are left out.
  defp groups(state) do
    state.order
    |> Enum.reverse()
    |> Enum.map(fn {adapter, _id} = key -> {adapter, {key, Map.fetch!(state.entries, key)}} end)
    |> Enum.reduce([], fn {adapter, item}, groups ->
      case List.keyfind(groups, adapter, 0) do
        nil -> groups ++ [{adapter, [item]}]
        {^adapter, items} -> List.keyreplace(groups, adapter, 0, {adapter, items ++ [item]})
      end
    end)
    |> Enum.map(fn {adapter, items} ->
      {adapter, items, Enum.flat_map(items, fn {_key, entry} -> changes(entry) end)}
    end)
    |> Enum.reject(fn {_adapter, _items, changes} -> changes == [] end)
    |> sort_groups(state.sorted)
  end

  # `flush_order: :sorted`: tables by name, rows by key. Whatever order the units of work
  # recorded their changes in, they then ask the database for rows in one and the same order.
  defp sort_groups(groups, false), do: groups

  defp sort_groups(groups, true) do
    groups
    |> Enum.map(fn {adapter, items, changes} ->
      {adapter, Enum.sort_by(items, fn {{_adapter, id}, _entry} -> id end),
       Enum.sort_by(changes, &(&1.aggregate |> DDD.Identity.key() |> to_string()))}
    end)
    |> Enum.sort_by(fn {adapter, _items, _changes} -> table_name(adapter) end)
  end

  defp table_name(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :schema, 0),
      do: adapter.schema().__schema__(:source),
      else: inspect(adapter)
  end

  # What one recorded entry asks of the database; nothing for one that need not be written.
  defp changes(%{op: :delete, skip: true}), do: []

  defp changes(%{op: :delete} = entry),
    do: [%{op: :delete, aggregate: entry.aggregate, expected: entry.base, events: []}]

  defp changes(%{op: :save, loaded: nil, base: 0} = entry),
    do: [%{op: :insert, aggregate: entry.current, expected: 0, events: entry.events}]

  defp changes(%{op: :save} = entry) do
    cond do
      data_changed?(entry) ->
        [%{op: :update, aggregate: entry.current, expected: entry.base, events: entry.events}]

      entry.events != [] ->
        # Nothing to store, but the events were decided on the state that was read: check that
        # nobody changed it since, without rewriting the row.
        [%{op: :check, aggregate: entry.current, expected: entry.base, events: entry.events}]

      true ->
        []
    end
  end

  defp write_groups(groups, sorted?) do
    Enum.reduce_while(groups, {:ok, @zero}, fn {adapter, items, changes}, {:ok, total} ->
      case write_group(adapter, items, changes, sorted?) do
        {:ok, stats} -> {:cont, {:ok, Map.merge(total, stats, fn _, a, b -> a + b end)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp write_group(adapter, items, changes, sorted?) do
    loaded? = Code.ensure_loaded?(adapter)

    batch =
      cond do
        loaded? and function_exported?(adapter, :__flush__, 2) ->
          adapter.__flush__(changes, sorted: sorted?)

        loaded? and function_exported?(adapter, :__flush__, 1) ->
          adapter.__flush__(changes)

        true ->
          :unsupported
      end

    case batch do
      :unsupported -> one_at_a_time(items)
      result -> result
    end
  end

  defp one_at_a_time(items) do
    Enum.reduce_while(items, {:ok, @zero}, fn {key, entry}, {:ok, stats} ->
      case write(key, entry) do
        :ok -> {:cont, {:ok, %{stats | written: stats.written + 1}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Without a transaction around the command (`transaction: false`) the writes still have to
  # land together, so the flush opens one on each repo that is not in one already.
  defp repos(groups) do
    for {adapter, _items, _changes} <- groups,
        Code.ensure_loaded?(adapter) and function_exported?(adapter, :repo, 0),
        uniq: true,
        do: adapter.repo()
  end

  defp in_transaction([], fun), do: fun.()

  defp in_transaction([repo | rest], fun) do
    if repo.in_transaction?(),
      do: in_transaction(rest, fun),
      else: transact(repo, fn -> in_transaction(rest, fun) end)
  end

  # `fun` returns `{:ok, stats}` or `{:error, error}`; an error rolls the transaction back.
  defp transact(repo, fun) do
    result =
      repo.transaction(fn ->
        case fun.() do
          {:ok, _stats} = ok -> ok
          {:error, error} -> repo.rollback(error)
        end
      end)

    case result do
      {:ok, ok} -> ok
      {:error, error} -> {:error, error}
    end
  end

  # Two failures of the database that the flush reports as an error and does not raise:
  #
  #   * A command can poison its own transaction (a failed inner transaction whose result it
  #     ignored) and still return `{:ok, _}`. The database then refuses every write, and that is
  #     the same system failure the command's commit would have reported.
  #   * The database aborts the transaction for a deadlock (or a serialization failure). The
  #     same writes will most likely succeed when run again: `:deadlock_detected`, which
  #     `retry_on_conflict` retries.
  defp guard(repos, fun) do
    fun.()
  rescue
    error ->
      cond do
        poisoned?(error) ->
          {:error,
           DDD.Error.infrastructure(
             code: :transaction_rolled_back,
             message: "the command's transaction was rolled back"
           )}

        Enum.any?(repos, &DDD.Dialect.retryable?(&1, error)) ->
          {:error, deadlock_error(error)}

        violation = Enum.find_value(repos, &DDD.Dialect.integrity_violation(&1, error)) ->
          {:error, constraint_error(violation)}

        true ->
          reraise error, __STACKTRACE__
      end
  end

  # The batched writes do not go through a changeset, so a constraint the database enforces
  # arrives as an exception; it is the same `:persistence_failed` the one-at-a-time save returns.
  defp constraint_error(%{kind: kind, constraint: constraint, detail: detail}) do
    DDD.Error.infrastructure(
      operation: :save,
      code: :persistence_failed,
      message: "could not save: #{kind} constraint #{constraint || "violated"}",
      details: %{constraint: constraint, kind: kind, detail: detail}
    )
  end

  defp poisoned?(%DBConnection.ConnectionError{} = error),
    do: Exception.message(error) =~ "transaction rolling back"

  defp poisoned?(_error), do: false

  @doc false
  # The error for a transaction the database aborted and that is worth running again.
  def deadlock_error(exception) do
    DDD.Error.infrastructure(
      code: :deadlock_detected,
      message:
        "the database aborted the transaction (a deadlock); running it again usually works",
      details: %{reason: Exception.message(exception)}
    )
  end

  defp write({_adapter, _id}, %{op: :delete, skip: true}), do: :ok

  defp write({adapter, _id}, %{op: :delete} = entry) do
    case adapter.__remove__(entry.aggregate) do
      :ok -> :ok
      {:error, :not_found} -> {:error, stale(entry.aggregate, entry.base, nil)}
      {:error, _} = error -> error
    end
  end

  defp write({adapter, _id}, %{op: :save} = entry) do
    if changed?(entry) do
      aggregate =
        entry.current
        |> Map.put(:version, entry.base)
        |> DDD.Schema.seal()
        |> DDD.Schema.with_events(entry.events)

      # `updated_at` was set when the aggregate was saved; it is written as it is.
      case adapter.__persist__(aggregate, stamp: false) do
        {:ok, _saved} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  # Nothing to write for an aggregate that was loaded and left as it was.
  defp changed?(entry), do: data_changed?(entry) or entry.events != []

  defp data_changed?(%{loaded: nil}), do: true
  defp data_changed?(%{loaded: loaded, current: current}), do: data(loaded) != data(current)

  # What the aggregate stores, without the bookkeeping: the seal, the pending events, the version
  # and `updated_at` (which is set by the write, so it never makes an aggregate "changed").
  defp data(aggregate),
    do: Map.drop(aggregate, [:__sealed__, :__pending_events__, :version, :updated_at])

  # `updated_at` is when the aggregate was stored: set it when something stored has changed, and
  # leave it when nothing has. A new aggregate keeps what `new` gave it.
  defp stamp(aggregate, loaded, base) do
    cond do
      loaded != nil and data(loaded) == data(aggregate) -> aggregate
      loaded == nil and base == 0 -> aggregate
      true -> DDD.Schema.touch(aggregate)
    end
  end
end
