defmodule DDD.Repository.Ecto do
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # (`__using__` generates a whole adapter; it is long because the adapter is)
  @moduledoc """
  Auto-generates a full Ecto repository adapter from a `DDD.Repository` port.

  Reads aggregate field metadata and port `find_by` declarations to generate:
    - Embedded Ecto schema (no separate schema module needed)
    - `find_by_id/1`
    - `save/1`  — aggregate upsert + outbox event inserts in ONE transaction
    - `delete/1`
    - `find_by_<field>/1` for every `find_by` on the port
    - `to_domain/1` and `from_domain/1`

  The whole aggregate is one row. Nested entities (`{:list, Entity}` / `{:one, Entity}`)
  are stored as `jsonb` and rebuilt into sealed structs on load; keys missing from
  old rows take the field default.

  `save/1` refuses structs that are not sealed (`DDD.Error` with code `:unsealed`).

  ## Usage

      defmodule MyApp.Infrastructure.OrderRepository do
        use DDD.Repository.Ecto,
          port:  MyApp.OrderRepository,
          repo:  MyApp.Repo,
          table: "orders"

        # Custom queries use schema() and repo() helpers
        def find_recent(limit \\\\ 10) do
          import Ecto.Query
          from(o in schema(), order_by: [desc: o.created_at], limit: ^limit)
          |> repo().all()
          |> Enum.map(&to_domain/1)
        end
      end

  ## Your own schema

  To store an aggregate in a table you already have, pass the Ecto schema that maps it:

      use DDD.Repository.Ecto,
        port:   MyApp.OrderRepository,
        repo:   MyApp.Repo,
        schema: MyApp.Infra.OrderRecord       # instead of `table:`; giving both is an error

  Each aggregate field is read from, and written to, the schema field of the same name (through
  `DDD.Type`). For anything else override `to_domain/1` and `from_domain/1`; the two-argument
  versions take the values for the fields that differ, so the rest stays by name:

      def to_domain(record), do: to_domain(record, customer_id: record.cust_ref)
      def from_domain(order), do: from_domain(order, cust_ref: order.customer_id)

  The save is the framework's: your schema's `changeset/2` is never called, and the upsert,
  the optimistic lock and the outbox insert stay in one transaction. The schema must have a
  `:version` field, the aggregate's identity as primary key (an `:identity` string column for a
  composite one), and `DDD.Type.Json` for nested entities, lists and maps
  (see `DDD.Type.ecto_type/1`). It is checked when the adapter is compiled; overriding
  `to_domain/1` or `from_domain/1` turns off the by-name checks (unmapped fields, JSON types).

  You own the table: `mix vic.gen.migration` skips the aggregate, and
  `DDD.Migration.schema_drift/2` / `DDD.Migration.table_drift/1` report a mismatch for a test.

  ## Migrations

  `mix vic.gen.migration MyApp.Order` generates and diffs table migrations;
  `mix vic.gen.outbox_migration` creates the outbox table.
  """

  @doc "Ecto type for a domain field type (see `DDD.Type`)."
  defdelegate ecto_type(type), to: DDD.Type

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      port = Keyword.fetch!(opts, :port)
      ecto_repo = Keyword.fetch!(opts, :repo)
      aggregate = port.__repo_aggregate__()
      find_bys = port.__repo_find_bys__()

      # `schema:` wires the aggregate to an Ecto schema you own (an existing table); without it the
      # adapter generates one. The table is then the schema's, so `table:` has no meaning.
      custom_schema = Keyword.get(opts, :schema)

      if custom_schema && Keyword.has_key?(opts, :table) do
        raise ArgumentError,
              "#{inspect(__MODULE__)}: give either `schema:` (the table is the schema's) or " <>
                "`table:` (a generated schema), not both"
      end

      table =
        Keyword.get_lazy(opts, :table, fn ->
          aggregate |> Module.split() |> List.last() |> Macro.underscore() |> Kernel.<>("s")
        end)

      agg_fields = aggregate.__ddd_fields__()
      field_types = Map.new(agg_fields, fn {name, type, _opts} -> {name, type} end)

      identity_parts = aggregate.__ddd_identity__()

      if identity_parts == [],
        do: raise("#{inspect(aggregate)} has no identity field defined")

      # A single-field identity is the table's primary key, in its own type. A composite one is
      # stored as a string in an `identity` column; its parts are ordinary columns.
      composite? = length(identity_parts) > 1

      {pk_field, pk_type} =
        case identity_parts do
          [{name, type, _opts}] -> {name, DDD.Type.ecto_type(type)}
          _composite -> {:identity, :string}
        end

      skipped = if composite?, do: [], else: [pk_field]
      column_names = agg_fields |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 in skipped))

      # ── Generate embedded Ecto schema ─────────────────────────────
      schema_module = custom_schema || Module.concat(__MODULE__, Schema)

      unless custom_schema do
        Module.create(
          schema_module,
          quote do
            use Ecto.Schema
            import Ecto.Changeset

            @primary_key {unquote(pk_field), unquote(pk_type), autogenerate: false}

            # created_at / updated_at are ordinary aggregate fields, managed by the domain.
            schema unquote(table) do
              for {name, type, _opts} <- unquote(Macro.escape(agg_fields)),
                  name not in unquote(skipped) do
                field(name, DDD.Repository.Ecto.ecto_type(type))
              end
            end

            def changeset(struct, params) do
              # `empty_values: []`: Ecto would otherwise store "" and "   " as NULL, so what is read
              # back would differ from what was saved. Whether a blank is allowed is the domain's rule.
              struct
              |> cast(params, [unquote(pk_field) | unquote(column_names)], empty_values: [])
              |> validate_required([unquote(pk_field)])
            end
          end,
          Macro.Env.location(__ENV__)
        )
      end

      @behaviour port
      require Logger

      # Read by `__before_compile__/1`, which checks a custom schema against the aggregate.
      @ddd_ecto_custom custom_schema
      @ddd_ecto_aggregate aggregate
      @ddd_ecto_pk {pk_field, pk_type}
      @before_compile DDD.Repository.Ecto

      def schema, do: unquote(schema_module)
      def repo, do: unquote(ecto_repo)

      @doc false
      def __ddd_adapter__ do
        %{
          aggregate: unquote(aggregate),
          schema: unquote(schema_module),
          repo: unquote(ecto_repo),
          custom_schema?: unquote(custom_schema != nil)
        }
      end

      # The adapter casts, not the schema: the save (upsert, lock, outbox) is the framework's, so a
      # `changeset/2` on a schema you own is never called. `empty_values: []`: "" is not NULL.
      defp cast_record(struct, params) do
        struct
        |> Ecto.Changeset.cast(params, unquote(schema_module).__schema__(:fields),
          empty_values: []
        )
        |> Ecto.Changeset.validate_required([unquote(pk_field)])
      end

      # ── find_by_id ─────────────────────────────────────────────────
      @impl port
      def find_by_id(id), do: DDD.UnitOfWork.read(__MODULE__, id, fn -> __load__(id) end)

      @doc false
      # The read itself, without the unit of work (see `DDD.UnitOfWork`).
      def __load__(id) do
        case unquote(ecto_repo).get(unquote(schema_module), id) do
          nil -> {:error, :not_found}
          record -> {:ok, to_domain(record)}
        end
      rescue
        # An id that is not even of the right type ("not-a-uuid") names nothing.
        Ecto.Query.CastError -> {:error, :not_found}
      end

      @doc false
      # Several aggregates by id in one query (see `DDD.UnitOfWork`, which preloads with it). An
      # id that is not even of the right type ("not-a-uuid") names nothing.
      def __load_many__(ids) do
        import Ecto.Query

        pk = unquote(pk_field)
        type = unquote(schema_module).__schema__(:type, pk)
        adapter = unquote(ecto_repo).__adapter__()

        # `cast` alone lets any string through as a `:binary_id`; the adapter's dump is what
        # refuses "not-a-uuid".
        valid =
          for id <- ids,
              {:ok, cast} <- [Ecto.Type.cast(type, id)],
              {:ok, _dumped} <- [Ecto.Type.adapter_dump(adapter, type, cast)],
              do: cast

        if valid == [] do
          []
        else
          from(r in unquote(schema_module), where: field(r, ^pk) in ^valid)
          |> unquote(ecto_repo).all()
          |> Enum.map(&to_domain/1)
        end
      end

      @doc false
      def __aggregate__, do: unquote(aggregate)

      # ── save: aggregate upsert + outbox in one transaction ─────────
      @impl port
      def save(aggregate), do: DDD.UnitOfWork.save(__MODULE__, aggregate, &__persist__/1)

      @doc false
      # The write itself, at once (see `DDD.UnitOfWork`, which calls it at the end of a command).
      def __persist__(aggregate, opts \\ []) do
        name = inspect(unquote(aggregate))
        id = DDD.Identity.key(aggregate)

        if DDD.Schema.sealed?(aggregate) do
          events = length(aggregate.__pending_events__)

          case do_save(aggregate, opts) do
            {:ok, _} = ok ->
              Logger.debug(
                "[repo] saved #{name} #{id} (#{events} event(s) written to the outbox)"
              )

              ok

            {:error, _} = error ->
              Logger.warning("[repo] could not save #{name} #{id}")
              error
          end
        else
          Logger.warning("[repo] refused to save #{name} #{id}: not produced by the framework")
          {:error, DDD.Schema.unsealed_error(aggregate)}
        end
      end

      defp do_save(aggregate, opts) do
        {events, clean} = unquote(aggregate).pop_events(aggregate)
        id = DDD.Identity.key(clean)
        params = from_domain(clean)

        unquote(ecto_repo).transaction(fn ->
          result =
            case unquote(ecto_repo).get(unquote(schema_module), id) do
              nil when clean.version in [0, nil] ->
                # A new aggregate is stored at version 1.
                unquote(schema_module)
                |> struct()
                |> cast_record(Map.put(params, :version, 1))
                |> unquote(ecto_repo).insert()

              nil ->
                # It was loaded at some version but the row is gone: someone deleted it.
                unquote(ecto_repo).rollback(
                  DDD.Repository.Ecto.stale_error(unquote(aggregate), id, clean.version, nil)
                )

              record ->
                expected = clean.version || 0
                # `stamp: false`: a unit of work has set `updated_at` already, and the caller
                # got that value back from `save`.
                params =
                  if Keyword.get(opts, :stamp, true),
                    do: DDD.Repository.Ecto.touch(params, unquote(Macro.escape(field_types))),
                    else: params

                if (record.version || 0) != expected do
                  unquote(ecto_repo).rollback(
                    DDD.Repository.Ecto.stale_error(
                      unquote(aggregate),
                      id,
                      expected,
                      record.version || 0
                    )
                  )
                end

                # Optimistic lock: `UPDATE ... WHERE id = ? AND version = ?`. A concurrent save
                # that committed after our read leaves no row to update.
                try do
                  %{record | version: expected}
                  |> cast_record(params)
                  |> Ecto.Changeset.optimistic_lock(:version)
                  # `force`: an unchanged aggregate still checks and advances its version.
                  |> unquote(ecto_repo).update(force: true)
                rescue
                  Ecto.StaleEntryError ->
                    unquote(ecto_repo).rollback(
                      DDD.Repository.Ecto.stale_error(unquote(aggregate), id, expected, nil)
                    )
                end
            end

          case result do
            {:error, changeset} ->
              unquote(ecto_repo).rollback(
                DDD.Error.infrastructure(
                  entity: unquote(aggregate),
                  entity_id: to_string(id),
                  operation: :save,
                  code: :persistence_failed,
                  message: "could not save #{inspect(unquote(aggregate))}",
                  details: %{errors: changeset.errors}
                )
              )

            {:ok, record} ->
              inserted_at = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

              rows =
                Enum.map(events, fn event ->
                  DDD.Repository.Ecto.event_row(unquote(aggregate), id, event, inserted_at)
                end)

              # One statement for all of the aggregate's events, not one round trip each.
              if rows != [], do: unquote(ecto_repo).insert_all(DDD.Outbox.Event, rows)

              to_domain(record)
          end
        end)
      end

      # ── delete ─────────────────────────────────────────────────────
      @impl port
      def delete(aggregate), do: DDD.UnitOfWork.delete(__MODULE__, aggregate, &__remove__/1)

      @doc false
      def __remove__(aggregate) do
        id = DDD.Identity.key(aggregate)

        case unquote(ecto_repo).get(unquote(schema_module), id) do
          nil ->
            {:error, :not_found}

          record ->
            {:ok, _} = unquote(ecto_repo).delete(record)
            Logger.info("[repo] deleted #{inspect(unquote(aggregate))} #{id}")
            :ok
        end
      end

      @doc false
      # Everything a unit of work collected for this adapter, written in a few statements (see
      # `DDD.Repository.Ecto.Flush`); `:unsupported` when the database has no batched writes.
      def __flush__(changes, opts \\ []) do
        DDD.Repository.Ecto.Flush.run(
          %{
            repo: unquote(ecto_repo),
            schema: unquote(schema_module),
            aggregate: unquote(aggregate),
            pk: unquote(pk_field),
            from_domain: &from_domain/1,
            cast: &cast_record/2
          },
          changes,
          opts
        )
      end

      # ── Auto-generated find_by_* ───────────────────────────────────
      for fields <- find_bys do
        fn_name =
          fields
          |> Enum.map_join("_and_", &Atom.to_string/1)
          |> then(&:"find_by_#{&1}")

        fn_args = Enum.map(fields, &Macro.var(&1, nil))

        @impl port
        def unquote(fn_name)(unquote_splicing(fn_args)) do
          import Ecto.Query

          DDD.UnitOfWork.guard_query!(__MODULE__, unquote(fn_name))

          query =
            Enum.reduce(
              Enum.zip(unquote(fields), [unquote_splicing(fn_args)]),
              from(r in unquote(schema_module)),
              fn {field, value}, q ->
                # Atoms, enums and references are stored as their column form.
                value =
                  DDD.Type.dump(Map.fetch!(unquote(Macro.escape(field_types)), field), value)

                where(q, [r], field(r, ^field) == ^value)
              end
            )

          query |> unquote(ecto_repo).all() |> Enum.map(&to_domain/1)
        rescue
          # A value of the wrong type ("not-a-uuid" for a uuid column) matches nothing.
          Ecto.Query.CastError -> []
        end
      end

      # ── Listing: filters, specifications, ordering, pages and cursors ──
      @doc false
      def __listing__ do
        %{
          repo: unquote(ecto_repo),
          schema: unquote(schema_module),
          types: unquote(Macro.escape(field_types)),
          pk: unquote(pk_field),
          map: &__MODULE__.to_domain/1
        }
      end

      @doc """
      The aggregates matching `:filter` / `:spec`, in `:order` (default: by identity), up to
      `:limit`. See `DDD.Listing` and `DDD.Filter`.
      """
      @impl port
      def list(opts \\ []) do
        DDD.UnitOfWork.guard_query!(__MODULE__, :list)
        DDD.Listing.list(__listing__(), opts)
      end

      @doc "One numbered `DDD.Page` of the matching aggregates. See `DDD.Listing`."
      @impl port
      def page(opts \\ []) do
        DDD.UnitOfWork.guard_query!(__MODULE__, :page)
        DDD.Listing.page(__listing__(), opts)
      end

      @doc "One `DDD.Slice` (keyset pagination, no totals) of the matching aggregates."
      @impl port
      def slice(opts \\ []) do
        DDD.UnitOfWork.guard_query!(__MODULE__, :slice)
        DDD.Listing.slice(__listing__(), opts)
      end

      @doc "How many aggregates match `:filter` / `:spec`."
      @impl port
      def count(opts \\ []) do
        DDD.UnitOfWork.guard_query!(__MODULE__, :count)
        DDD.Listing.count(__listing__(), opts)
      end

      # ── Domain ↔ Schema mapping ────────────────────────────────────
      @doc "Convert Ecto schema record to a sealed domain aggregate struct."
      def to_domain(record), do: to_domain(record, [])

      @doc """
      `to_domain/1` with `overrides`: a keyword list or map of aggregate field => the stored
      value, for a field the schema calls something else. It still goes through `DDD.Type`.

          def to_domain(record), do: to_domain(record, customer_id: record.cust_ref)
      """
      def to_domain(record, overrides) do
        overrides = Map.new(overrides)

        params =
          for {name, type, opts} <- unquote(Macro.escape(agg_fields)), into: %{} do
            raw =
              case overrides do
                %{^name => value} -> value
                _ -> Map.get(record, name)
              end

            # Columns added after a row was written are NULL: use the declared default.
            value =
              case DDD.Repository.Ecto.load_field(type, raw) do
                nil -> Keyword.get(opts, :default)
                value -> value
              end

            {name, value}
          end

        unquote(aggregate) |> struct(params) |> DDD.Schema.seal()
      end

      @doc "Convert domain aggregate struct to Ecto-compatible params."
      def from_domain(aggregate), do: from_domain(aggregate, [])

      @doc """
      `from_domain/1` with `overrides`: a keyword list or map of schema field => value, merged
      over the by-name params. Params the schema has no field for are ignored on save.

          def from_domain(order), do: from_domain(order, cust_ref: order.customer_id)
      """
      def from_domain(aggregate, overrides) do
        params =
          for {name, type, _opts} <- unquote(Macro.escape(agg_fields)), into: %{} do
            {name, DDD.Repository.Ecto.dump_field(type, Map.get(aggregate, name))}
          end

        # A composite identity is also stored whole, as the string the repository looks up by.
        params =
          if unquote(composite?),
            do: Map.put(params, :identity, unquote(aggregate).identity(aggregate)),
            else: params

        Map.merge(params, Map.new(overrides))
      end

      defoverridable find_by_id: 1, save: 1, delete: 1, to_domain: 1, from_domain: 1
    end
  end

  @doc false
  # Checks a `schema:` you own against the aggregate, once the adapter's own functions are
  # defined (only then is it known whether `to_domain/1` / `from_domain/1` were overridden).
  defmacro __before_compile__(env) do
    if schema = Module.get_attribute(env.module, :ddd_ecto_custom) do
      aggregate = Module.get_attribute(env.module, :ddd_ecto_aggregate)
      pk = Module.get_attribute(env.module, :ddd_ecto_pk)

      overridden? =
        Enum.any?([to_domain: 1, from_domain: 1], fn function ->
          case Module.get_definition(env.module, function) do
            # The generated defaults carry this module as their macro context; yours do not.
            {:v1, _kind, meta, _clauses} -> Keyword.get(meta, :context) != __MODULE__
            _ -> false
          end
        end)

      case schema_problems(aggregate, schema, pk, overridden?) do
        [] ->
          :ok

        problems ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "#{inspect(env.module)}: #{inspect(schema)} does not fit #{inspect(aggregate)}:\n" <>
                Enum.map_join(problems, "\n", &("  * " <> &1))
      end
    end

    nil
  end

  @doc """
  What is wrong with `schema` as the storage of `aggregate`, as a list of messages (empty: fine).

  `pk` is the `{field, ecto_type}` the aggregate's identity needs. With `overridden?` (you
  wrote `to_domain/1` or `from_domain/1`) the by-name mapping is yours, so unmapped fields and
  JSON column types are not checked; the primary key and the `:version` column always are.
  """
  @spec schema_problems(module(), module(), {atom(), Ecto.Type.t()}, boolean()) :: [String.t()]
  def schema_problems(aggregate, schema, {pk_field, pk_type}, overridden?) do
    case Code.ensure_compiled(schema) do
      {:module, _} ->
        if function_exported?(schema, :__schema__, 1),
          do: check_schema(aggregate, schema, {pk_field, pk_type}, overridden?),
          else: ["it is not an Ecto schema"]

      _ ->
        ["it could not be found"]
    end
  end

  defp check_schema(aggregate, schema, {pk_field, pk_type}, overridden?) do
    fields = schema.__schema__(:fields)

    primary_key =
      cond do
        schema.__schema__(:primary_key) != [pk_field] ->
          [
            "its primary key is #{inspect(schema.__schema__(:primary_key))}, " <>
              "expected [#{inspect(pk_field)}] (the aggregate's identity)"
          ]

        not same_type?(schema.__schema__(:type, pk_field), pk_type) ->
          [
            "primary key #{inspect(pk_field)} is #{inspect(schema.__schema__(:type, pk_field))}, " <>
              "expected #{inspect(pk_type)}"
          ]

        true ->
          []
      end

    version =
      if :version in fields,
        do: [],
        else: ["it has no :version field (optimistic locking needs a version column)"]

    primary_key ++ version ++ if(overridden?, do: [], else: mapping_problems(aggregate, schema))
  end

  defp mapping_problems(aggregate, schema) do
    fields = schema.__schema__(:fields)
    agg_fields = aggregate.__ddd_fields__()

    unmapped = for {name, _type, _opts} <- agg_fields, name not in fields, do: name

    unmapped_problem =
      if unmapped == [],
        do: [],
        else: [
          "no schema field for #{Enum.map_join(unmapped, ", ", &inspect/1)} " <>
            "(name them the same, or override to_domain/1 and from_domain/1)"
        ]

    json_problems =
      for {name, type, _opts} <- agg_fields,
          name in fields,
          expected = DDD.Type.ecto_type(type),
          actual = schema.__schema__(:type, name),
          not json_fits?(expected, actual) do
        "#{inspect(name)} is stored as JSON, so its type must be DDD.Type.Json " <>
          "(see DDD.Type.ecto_type/1), found #{inspect(actual)}"
      end

    unmapped_problem ++ json_problems
  end

  # Nested entities, lists and maps live in one JSON column. `:map` also takes a plain map.
  defp json_fits?(DDD.Type.Json, actual), do: actual == DDD.Type.Json
  defp json_fits?(:map, actual), do: actual in [:map, DDD.Type.Json]
  defp json_fits?(_scalar, _actual), do: true

  defp same_type?(actual, expected), do: normalize_type(actual) == normalize_type(expected)

  defp normalize_type(Ecto.UUID), do: :binary_id
  defp normalize_type(:id), do: :integer
  defp normalize_type(type), do: type

  @doc false
  # The error for a save that lost against a concurrent one (optimistic locking). It is an
  # infrastructure error: the same command, run again on fresh data, may well succeed.
  def stale_error(aggregate, id, expected, actual) do
    :telemetry.execute([:ddd, :repository, :conflict], %{count: 1}, %{
      aggregate: aggregate,
      id: to_string(id),
      expected_version: expected,
      actual_version: actual
    })

    DDD.Error.infrastructure(
      entity: aggregate,
      entity_id: to_string(id),
      operation: :save,
      code: :stale_aggregate,
      message:
        "#{inspect(aggregate)} #{id} was changed by someone else (expected version " <>
          "#{inspect(expected)}, found #{inspect(actual)}); reload it and try again",
      details: %{id: to_string(id), expected_version: expected, actual_version: actual}
    )
  end

  @doc false
  # `params` of an aggregate that is being updated, with `updated_at` set to now (when it has one).
  def touch(params, field_types) do
    case field_types do
      %{updated_at: type} ->
        Map.put(params, :updated_at, dump_field(type, DateTime.utc_now()))

      _ ->
        params
    end
  end

  @doc false
  # A row of the `domain_events` outbox for `event`, emitted by the aggregate `aggregate`
  # (a module) with identity `id`.
  def event_row(aggregate, id, event, inserted_at) do
    %{
      id: event.event_id,
      event_type: event.__struct__ |> Module.split() |> Enum.join("."),
      # The event is linked to its aggregate by emit_event/2; fall back to this one.
      aggregate_id: event.aggregate_id || to_string(id),
      aggregate_type: event.aggregate_type || aggregate |> Module.split() |> Enum.join("."),
      payload: event |> Map.from_struct() |> stringify_keys(),
      occurred_at: DDD.Dialect.usec(event.occurred_at),
      published_at: nil,
      inserted_at: inserted_at
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      val = if is_map(v) and not is_struct(v), do: stringify_keys(v), else: v
      {key, val}
    end)
  end

  @doc false
  defdelegate dump_field(type, value), to: DDD.Type, as: :dump

  @doc false
  defdelegate load_field(type, value), to: DDD.Type, as: :load
end
