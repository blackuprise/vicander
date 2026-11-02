defmodule DDD.Projection do
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # (`__before_compile__` generates the whole projection; it is long because the projection is)
  @moduledoc """
  A read model: a denormalized table kept up to date by domain events.

  Queries read the table directly instead of loading and folding whole aggregates. A projection
  is an event handler (`DDD.EventHandler`), so it is fed by the outbox and inherits its
  guarantees: each event is applied in its own transaction together with the delivery record,
  so a retry or a duplicate delivery never counts an event twice.

      defmodule MyApp.Projections.ListSummary do
        use DDD.Projection,
          table: "todo_list_summaries",
          key: :list_id,
          events: [ListCreated, ItemAdded, ItemCompleted, ItemRemoved]

        projection do
          description "One row per list: title, owner, open and done counts"
          field :list_id, :uuid
          field :owner_id, :uuid
          field :title, :string
          field :open_count, :integer, default: 0
          field :done_count, :integer, default: 0
        end

        on %ListCreated{} = e, do: {:upsert, %{owner_id: e.owner_id, title: e.title}}
        on %ItemAdded{}, do: {:inc, :open_count, 1}
        on %ItemCompleted{}, do: {:inc, open_count: -1, done_count: 1}
        on %ItemRemoved{}, do: {:inc, :open_count, -1}
      end

      MyApp.Projections.ListSummary.subscribe()      # before the outbox poller starts

  ## Options

    * `:table` - the table (required)
    * `:key` - the field that is the primary key, one row per key (required)
    * `:events` - the event modules the projection reacts to (required)
    * `:repo` - default: the configured repo (`config :vicander, repo: MyApp.Repo`)
    * `:key_from` - the event field holding the key, default `:aggregate_id`, which is right
      when the projection is one row per aggregate

  ## What an `on` clause returns

  `on` matches an event like a function head, and returns what to do to the row of that event's
  key (a list of these is applied in order):

  | return | effect |
  |---|---|
  | `{:upsert, %{field: value}}` | create the row (with the field defaults), or set these fields |
  | `{:update, %{field: value}}` | set these fields; nothing if there is no row |
  | `{:inc, :field, n}` / `{:inc, field: n, other: m}` | add `n` to numeric fields, creating the row if needed |
  | `:delete` | delete the row |
  | `:skip` | do nothing |
  | `{:error, reason}` | like any handler: a business error is a rejection, an infrastructure error is retried |

  An event the projection lists but has no `on` clause for is skipped.

  ## The table

  `mix vic.gen.migration MyApp.Projections.ListSummary` writes the migration, like for an
  aggregate (the key is the primary key). Apply new fields the same way.

  ## Reading

  The module gets `get/1` (`{:ok, map}` or `{:error, :not_found}`), and the listing functions
  `list/1`, `page/1`, `slice/1`, `count/1` with filters, ordering and cursors (see
  `DDD.Listing`). Rows come back as plain maps with the declared fields.

      {:ok, page} = ListSummary.page(filter: [owner_id: id, open_count: {:gt, 0}], order: :title)

  A projection is eventually consistent. Decisions belong to the aggregate; never base a
  business rule on a projection.

  ## Operating it

    * `lag/0` - how many events are waiting for this projection and how long the oldest has
      waited (`DDD.Health` and `DDD.Telemetry` report it).
    * `rebuild/0` - empty the table and replay every stored event into it, in order. Use it
      after fixing a projection, or after adding one for events that already happened. It needs
      the events to still be in `domain_events`. Readers see the table fill up again while it
      runs, so run it in a quiet period; run it again if it is interrupted. `mix
      vic.projection.rebuild` runs it from the command line.
  """

  import Ecto.Query, only: [from: 2]
  require Ecto.Query

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    key = Keyword.fetch!(opts, :key)
    events = Keyword.fetch!(opts, :events)
    repo = Keyword.get(opts, :repo, :default)
    key_from = Keyword.get(opts, :key_from, :aggregate_id)

    quote do
      use DDD.EventHandler, events: unquote(events), repo: unquote(repo)
      import DDD.Projection, only: [projection: 1, field: 2, field: 3, description: 1, on: 2]

      Module.register_attribute(__MODULE__, :projection_clauses, accumulate: true)
      @projection_fields []
      @projection_description nil
      @projection_table unquote(table)
      @projection_key unquote(key)
      @projection_key_from unquote(key_from)
      @projection_repo unquote(repo)
      @projection_events unquote(events)
      @before_compile DDD.Projection
    end
  end

  @doc "Declares the projection's fields. `description` and `field` go inside."
  defmacro projection(do: block), do: block

  @doc "Describe the projection in a sentence."
  defmacro description(text) do
    quote do: @projection_description(unquote(text))
  end

  @doc "A column of the projection table. Options: `:default`, `:description`."
  defmacro field(name, type, opts \\ []) do
    quote do
      @projection_fields [
        {unquote(name), DDD.Type.normalize!(unquote(type)), unquote(opts)} | @projection_fields
      ]
    end
  end

  @doc "What to do to a row when an event matching `pattern` arrives (see the module docs)."
  defmacro on(pattern, do: body) do
    quote do
      @projection_clauses {unquote(Macro.escape(pattern)), unquote(Macro.escape(body))}
    end
  end

  defmacro __before_compile__(env) do
    module = env.module
    fields = module |> Module.get_attribute(:projection_fields) |> Enum.reverse()
    key = Module.get_attribute(module, :projection_key)
    table = Module.get_attribute(module, :projection_table)

    {_, key_type, _} =
      List.keyfind(fields, key, 0) ||
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "#{inspect(module)}: the key #{inspect(key)} is not a declared field " <>
              "(fields: #{inspect(Enum.map(fields, &elem(&1, 0)))})"

    events =
      module |> Module.get_attribute(:projection_events) |> Enum.map(&Macro.expand(&1, env))

    schema_module = Module.concat(module, Schema)

    field_asts =
      for {name, type, _opts} <- fields, name != key do
        quote do: field(unquote(name), unquote(Macro.escape(DDD.Type.ecto_type(type))))
      end

    schema_body =
      quote do
        use Ecto.Schema

        @primary_key {unquote(key), unquote(Macro.escape(DDD.Type.ecto_type(key_type))),
                      autogenerate: false}
        schema unquote(table) do
          (unquote_splicing(field_asts))
        end
      end

    spec = %{
      module: module,
      schema: schema_module,
      repo: Module.get_attribute(module, :projection_repo),
      table: table,
      key: key,
      key_type: key_type,
      key_from: Module.get_attribute(module, :projection_key_from),
      fields: for({name, type, _opts} <- fields, do: {name, type}),
      defaults:
        for {name, type, opts} <- fields,
            name != key,
            Keyword.has_key?(opts, :default),
            into: %{} do
          {name, DDD.Type.dump(type, Keyword.fetch!(opts, :default))}
        end,
      event_types: Enum.map(events, &(&1 |> Module.split() |> Enum.join("."))),
      name: inspect(module)
    }

    clauses =
      for {pattern, body} <- module |> Module.get_attribute(:projection_clauses) |> Enum.reverse() do
        quote do
          def __project__(unquote(pattern)), do: unquote(body)
        end
      end

    quote do
      Module.create(
        unquote(schema_module),
        unquote(Macro.escape(schema_body)),
        Macro.Env.location(__ENV__)
      )

      # What `mix vic.gen.migration` reads, so a projection's table is generated like an
      # aggregate's.
      @doc false
      def __ddd_kind__, do: :projection
      @doc false
      def __ddd_table__, do: unquote(table)
      @doc false
      def __ddd_fields__, do: unquote(Macro.escape(fields))
      @doc false
      def __ddd_identity__, do: [{unquote(key), unquote(Macro.escape(key_type)), []}]
      @doc false
      def __ddd_description__, do: @projection_description
      @doc false
      def __projection__ do
        spec = unquote(Macro.escape(spec))
        %{spec | repo: DDD.Config.repo(spec.repo)}
      end

      unquote_splicing(clauses)
      @doc false
      def __project__(_event), do: :skip

      @doc "The Ecto schema of the projection table."
      def schema, do: unquote(schema_module)

      @impl DDD.EventHandler
      def handle(event), do: DDD.Projection.handle(__projection__(), event, __project__(event))

      @doc "The row with this key: `{:ok, map}` or `{:error, :not_found}`."
      def get(key), do: DDD.Projection.get(__projection__(), key)

      @doc "The rows matching `:filter`, in `:order`. See `DDD.Listing`."
      def list(opts \\ []), do: DDD.Listing.list(DDD.Projection.listing(__projection__()), opts)

      @doc "One numbered `DDD.Page` of rows. See `DDD.Listing`."
      def page(opts \\ []), do: DDD.Listing.page(DDD.Projection.listing(__projection__()), opts)

      @doc "One `DDD.Slice` of rows, continuing from a cursor. See `DDD.Listing`."
      def slice(opts \\ []), do: DDD.Listing.slice(DDD.Projection.listing(__projection__()), opts)

      @doc "How many rows match `:filter`."
      def count(opts \\ []), do: DDD.Listing.count(DDD.Projection.listing(__projection__()), opts)

      @doc "How many events wait for this projection, and how long the oldest has waited."
      def lag, do: DDD.Projection.lag(__projection__())

      @doc "Empty the table and replay every stored event into it. See `DDD.Projection`."
      def rebuild, do: DDD.Projection.rebuild(__projection__())
    end
  end

  # ── Handling an event ────────────────────────────────────────────────────

  @doc false
  def handle(_spec, _event, :skip), do: :ok

  def handle(spec, event, op) do
    case Map.get(event, spec.key_from) do
      nil ->
        {:error,
         DDD.Error.business(
           entity: spec.module,
           operation: :project,
           code: :missing_key,
           message: "#{inspect(event.__struct__)} has no #{inspect(spec.key_from)} to key by"
         )}

      key ->
        apply_ops(spec, DDD.Type.dump(spec.key_type, key), op)
    end
  end

  defp apply_ops(spec, key, ops) when is_list(ops) do
    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case apply_op(spec, key, op) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_ops(spec, key, op), do: apply_op(spec, key, op)

  defp apply_op(_spec, _key, :skip), do: :ok
  defp apply_op(_spec, _key, {:error, _reason} = error), do: error

  defp apply_op(spec, key, :delete) do
    spec.repo.delete_all(from(r in spec.schema, where: field(r, ^spec.key) == ^key))
    :ok
  end

  defp apply_op(spec, key, {:update, changes}) do
    case dump_changes(spec, changes) do
      [] ->
        :ok

      set ->
        spec.repo.update_all(from(r in spec.schema, where: field(r, ^spec.key) == ^key), set: set)
        :ok
    end
  end

  defp apply_op(spec, key, {:upsert, changes}) do
    set = dump_changes(spec, changes)
    row = spec.defaults |> Map.merge(Map.new(set)) |> Map.put(spec.key, key)

    on_conflict = if set == [], do: :nothing, else: {:replace, Keyword.keys(set)}

    spec.repo.insert_all(spec.schema, [row],
      on_conflict: on_conflict,
      conflict_target: [spec.key]
    )

    :ok
  end

  defp apply_op(spec, key, {:inc, field, amount}) when is_atom(field),
    do: apply_op(spec, key, {:inc, [{field, amount}]})

  defp apply_op(spec, key, {:inc, incs}) when is_list(incs) do
    check_fields!(spec, Keyword.keys(incs))

    for {field, amount} <- incs do
      type = spec.fields |> List.keyfind!(field, 0) |> elem(1)

      unless type in [:integer, :float] and is_number(amount) do
        raise ArgumentError,
              "#{inspect(spec.module)}: cannot increment #{inspect(field)} (#{inspect(type)}) " <>
                "by #{inspect(amount)}: only :integer and :float fields take numbers"
      end
    end

    # A new row starts from the defaults, with the increment applied; an existing one is
    # incremented in place by the database, so concurrent events never overwrite each other.
    start =
      for {field, amount} <- incs, into: %{}, do: {field, (spec.defaults[field] || 0) + amount}

    row = spec.defaults |> Map.merge(start) |> Map.put(spec.key, key)

    spec.repo.insert_all(spec.schema, [row],
      on_conflict: [inc: incs],
      conflict_target: [spec.key]
    )

    :ok
  end

  defp apply_op(spec, _key, other) do
    raise ArgumentError,
          "#{inspect(spec.module)}: an `on` clause returned #{inspect(other)}; expected " <>
            "{:upsert, map}, {:update, map}, {:inc, field, n}, :delete, :skip, {:error, reason} " <>
            "or a list of those"
  end

  defp dump_changes(spec, changes) do
    changes = Enum.to_list(changes)
    check_fields!(spec, Keyword.keys(changes))

    for {field, value} <- changes do
      {field, DDD.Type.dump(spec.fields |> List.keyfind!(field, 0) |> elem(1), value)}
    end
  end

  defp check_fields!(spec, names) do
    declared = for {name, _type} <- spec.fields, name != spec.key, do: name

    for name <- names, name not in declared do
      raise ArgumentError,
            "#{inspect(spec.module)} has no field #{inspect(name)} to change " <>
              "(fields: #{inspect(declared)}; the key can't be changed)"
    end

    :ok
  end

  # ── Reading ──────────────────────────────────────────────────────────────

  @doc false
  def get(spec, key) do
    case spec.repo.get(spec.schema, DDD.Type.dump(spec.key_type, key)) do
      nil -> {:error, :not_found}
      record -> {:ok, to_map(spec, record)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc false
  def listing(spec) do
    %{
      repo: spec.repo,
      schema: spec.schema,
      types: Map.new(spec.fields),
      pk: spec.key,
      map: &to_map(spec, &1)
    }
  end

  @doc false
  def to_map(spec, record) do
    for {name, type} <- spec.fields, into: %{} do
      {name, DDD.Type.load(type, Map.get(record, name))}
    end
  end

  # ── Operating ────────────────────────────────────────────────────────────

  @doc false
  # The events this projection has not handled yet: how many, and how long the oldest has been
  # waiting (by the database clock).
  def lag(spec) do
    pending =
      Ecto.Query.from(e in DDD.Outbox.Event,
        as: :event,
        where:
          e.event_type in ^spec.event_types and
            (is_nil(e.resolution) or e.resolution != "discarded") and
            not exists(
              from(d in DDD.Outbox.Delivery,
                where: d.event_id == parent_as(:event).id and d.handler == ^spec.name
              )
            )
      )

    oldest = spec.repo.one(Ecto.Query.from(e in pending, select: min(e.occurred_at)))
    now = DDD.Dialect.for_repo(spec.repo).now(spec.repo)

    %{
      pending: spec.repo.aggregate(pending, :count),
      oldest_pending_age_ms:
        if(oldest, do: max(DateTime.diff(now, oldest, :millisecond), 0), else: 0)
    }
  end

  @doc false
  def rebuild(spec) do
    DDD.Telemetry.span([:ddd, :projection, :rebuild], %{projection: spec.module}, fn ->
      result = do_rebuild(spec)

      case result do
        {:ok, count} -> {{:ok, %{events: count}}, %{events: count}}
        {:error, _} = error -> {error, %{}}
      end
    end)
  end

  # Not one big transaction: a handler that rejects an event rolls back its own (nested)
  # transaction, and inside an outer one that would doom the whole rebuild. Each event is
  # applied in its own transaction, like in normal delivery.
  defp do_rebuild(spec) do
    spec.repo.transaction(fn ->
      spec.repo.delete_all(spec.schema)

      spec.repo.delete_all(
        Ecto.Query.from(d in DDD.Outbox.Delivery, where: d.handler == ^spec.name)
      )
    end)

    replay(spec, nil, 0)
  end

  # One page of the events this projection handles, after `cursor` (`{occurred_at, id}` of the
  # last one replayed). The cursor is an ordinary comparison rather than a row-value one, which
  # not every database supports.
  defp replay_query(spec, cursor) do
    base =
      Ecto.Query.from(e in DDD.Outbox.Event,
        where:
          e.event_type in ^spec.event_types and
            (is_nil(e.resolution) or e.resolution != "discarded"),
        order_by: [asc: e.occurred_at, asc: e.id],
        limit: 500,
        select: map(e, [:id, :event_type, :aggregate_id, :aggregate_type, :payload, :occurred_at])
      )

    case cursor do
      nil ->
        base

      {occurred_at, id} ->
        Ecto.Query.from(e in base,
          where:
            e.occurred_at > ^occurred_at or
              (e.occurred_at == ^occurred_at and e.id > type(^id, :binary_id))
        )
    end
  end

  defp replay(spec, cursor, count) do
    rows = spec.repo.all(replay_query(spec, cursor))

    case replay_rows(spec, rows) do
      :ok when rows == [] ->
        {:ok, count}

      :ok ->
        last = List.last(rows)
        replay(spec, {last.occurred_at, last.id}, count + length(rows))

      {:error, _} = error ->
        error
    end
  end

  defp replay_rows(spec, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      with {:ok, event} <- DDD.Outbox.Poller.build_event(row),
           result when result in [:delivered, :skipped] or elem(result, 0) == :rejected <-
             DDD.EventHandler.deliver(spec.module, event, row.id, spec.repo) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, replay_error(spec, row, reason)}}
      end
    end)
  end

  defp replay_error(spec, row, reason) do
    DDD.Error.infrastructure(
      entity: spec.module,
      operation: :rebuild,
      code: :rebuild_failed,
      message:
        "replaying #{row.event_type} (#{row.aggregate_id}) failed; the projection is partial, " <>
          "run the rebuild again once the cause is fixed",
      details: %{
        event_type: row.event_type,
        aggregate_id: row.aggregate_id,
        reason: inspect(reason)
      }
    )
  end
end
