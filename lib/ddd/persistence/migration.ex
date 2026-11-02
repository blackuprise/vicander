defmodule DDD.Migration do
  @moduledoc """
  Snapshot-based migration generation for aggregates stored by `DDD.Repository.Ecto`.

  `generate/2` compares an aggregate's current columns with the snapshot saved by the
  previous run and writes a new timestamped migration containing only the difference
  (`create table` the first time). Nothing already generated is overwritten.

  Safeguards:

    * Removing a column or changing its type loses data, so it is refused unless
      `allow_destructive: true` (`--allow-destructive` on the Mix task).
    * A rename must be explicit: `renames: %{"old" => "new"}` (`--rename old:new`) or
      `field :name, :string, renamed_from: :old_name` on the field. Otherwise it is a
      remove plus an add.
    * Edits inside a nested `jsonb` entity do not change columns. Old rows keep the old
      shape; the serializer fills defaults for missing keys when loading.

  `drift/3` compares an aggregate with the real table columns, for use in a test.
  """

  # Entities and aggregates always have these (see DDD.Schema); they are never nullable.
  @timestamp_columns ["created_at", "updated_at"]

  @type column :: %{String.t() => String.t() | boolean()}

  @doc "Default table name for an aggregate (matches `DDD.Repository.Ecto`)."
  @spec default_table(module()) :: String.t()
  def default_table(aggregate) do
    # A projection names its own table; an aggregate's is derived from its module name.
    if function_exported?(aggregate, :__ddd_table__, 0),
      do: aggregate.__ddd_table__(),
      else: aggregate |> Module.split() |> List.last() |> Macro.underscore() |> Kernel.<>("s")
  end

  @doc "Columns the Ecto adapter maps an aggregate to (`created_at` / `updated_at` included)."
  @spec columns(module()) :: [column()]
  def columns(aggregate) do
    parts =
      case aggregate.__ddd_identity__() do
        [] -> raise "#{inspect(aggregate)} has no identity"
        parts -> Enum.map(parts, &elem(&1, 0))
      end

    composite? = length(parts) > 1

    field_columns =
      for {name, type, _opts} <- aggregate.__ddd_fields__() do
        column = %{
          "name" => Atom.to_string(name),
          "type" => type |> DDD.Type.column_type() |> inspect(),
          "primary_key" => not composite? and name in parts
        }

        # The parts of a composite identity are always present.
        if composite? and name in parts, do: Map.put(column, "null", false), else: column
      end

    # A composite identity is stored whole, as a string: that column is the primary key.
    if composite?,
      do: [%{"name" => "identity", "type" => ":string", "primary_key" => true} | field_columns],
      else: field_columns
  end

  @doc "The names of the identity fields (`[\"id\"]`, or the parts of a composite identity)."
  @spec identity(module()) :: [String.t()]
  def identity(aggregate),
    do: aggregate.__ddd_identity__() |> Enum.map(fn {name, _, _} -> Atom.to_string(name) end)

  @doc "Renames declared on fields with `renamed_from:`, as `%{old => new}`."
  @spec declared_renames(module()) :: %{String.t() => String.t()}
  def declared_renames(aggregate) do
    for {name, _type, opts} <- aggregate.__ddd_fields__(),
        old = Keyword.get(opts, :renamed_from),
        into: %{} do
      {Atom.to_string(old), Atom.to_string(name)}
    end
  end

  @doc """
  Diff two column lists.

  Returns `%{added: [column], removed: [column], renamed: [{old, new}], changed: [{name, old_type, new_type}]}`.
  """
  @spec diff([column()], [column()], %{String.t() => String.t()}) :: map()
  def diff(old, new, renames \\ %{}) do
    old_by_name = Map.new(old, &{&1["name"], &1})
    new_by_name = Map.new(new, &{&1["name"], &1})

    renamed =
      for {from, to} <- renames,
          Map.has_key?(old_by_name, from),
          Map.has_key?(new_by_name, to),
          not Map.has_key?(new_by_name, from),
          do: {from, to}

    renamed_from = Enum.map(renamed, &elem(&1, 0))
    renamed_to = Enum.map(renamed, &elem(&1, 1))

    added =
      Enum.filter(
        new,
        &(&1["name"] not in renamed_to and not Map.has_key?(old_by_name, &1["name"]))
      )

    removed =
      Enum.filter(
        old,
        &(&1["name"] not in renamed_from and not Map.has_key?(new_by_name, &1["name"]))
      )

    kept = Enum.filter(new, &Map.has_key?(old_by_name, &1["name"]))

    changed =
      for column <- kept, old_by_name[column["name"]]["type"] != column["type"] do
        {column["name"], old_by_name[column["name"]]["type"], column["type"]}
      end ++
        for {from, to} <- renamed, old_by_name[from]["type"] != new_by_name[to]["type"] do
          {to, old_by_name[from]["type"], new_by_name[to]["type"]}
        end

    %{added: added, removed: removed, renamed: renamed, changed: changed}
  end

  @doc "True when applying the diff can lose data."
  @spec destructive?(map()) :: boolean()
  def destructive?(%{removed: removed, changed: changed}), do: removed != [] or changed != []

  @doc "True when the diff changes nothing."
  @spec empty?(map()) :: boolean()
  def empty?(%{added: [], removed: [], renamed: [], changed: []}), do: true
  def empty?(_), do: false

  @doc """
  Generate the migration for `aggregate`.

  Options: `:table`, `:snapshot_dir` (default `priv/ddd_snapshots`), `:migrations_path`
  (default `priv/repo/migrations`), `:repo` (default: the configured repo), `:renames`,
  `:allow_destructive`, `:timestamp`.

  Returns `{:ok, :unchanged}`, `{:ok, migration_path}` or `{:error, reason}`.
  """
  @spec generate(module(), keyword()) :: {:ok, :unchanged | Path.t()} | {:error, term()}
  def generate(aggregate, opts \\ []) do
    snapshot_dir = Keyword.get(opts, :snapshot_dir, "priv/ddd_snapshots")
    migrations_path = Keyword.get(opts, :migrations_path, "priv/repo/migrations")
    repo = Keyword.get_lazy(opts, :repo, &DDD.Config.repo!/0)
    timestamp = Keyword.get_lazy(opts, :timestamp, &timestamp/0)
    snapshot_path = Path.join(snapshot_dir, snapshot_name(aggregate))
    new = columns(aggregate)
    new_identity = identity(aggregate)

    case read_snapshot(snapshot_path) do
      nil ->
        table = Keyword.get(opts, :table, default_table(aggregate))
        name = "create_#{table}"

        write(
          snapshot_path,
          migrations_path,
          timestamp,
          name,
          render_create(repo, name, table, new),
          table,
          new,
          new_identity
        )

      %{"table" => table, "columns" => old} = snapshot ->
        renames = opts |> Keyword.get(:renames, %{}) |> Map.merge(declared_renames(aggregate))
        diff = diff(old, new, renames)

        # Snapshots from before composite identities have no "identity": it was the primary key.
        old_identity =
          snapshot["identity"] || for(%{"primary_key" => true, "name" => n} <- old, do: n)

        identity_change = if old_identity != new_identity, do: {old_identity, new_identity}

        cond do
          empty?(diff) and is_nil(identity_change) ->
            {:ok, :unchanged}

          (destructive?(diff) or identity_change != nil) and
              not Keyword.get(opts, :allow_destructive, false) ->
            {:error, {:destructive, destructive_summary(diff, identity_change)}}

          true ->
            name = "alter_#{table}_#{timestamp}"

            write(
              snapshot_path,
              migrations_path,
              timestamp,
              name,
              render_alter(repo, name, table, diff, identity_change),
              table,
              new,
              new_identity
            )
        end
    end
  end

  defp write(snapshot_path, migrations_path, timestamp, name, content, table, columns, identity) do
    path = Path.join(migrations_path, "#{timestamp}_#{name}.exs")
    File.mkdir_p!(migrations_path)
    File.mkdir_p!(Path.dirname(snapshot_path))
    File.write!(path, content)

    File.write!(
      snapshot_path,
      Jason.encode!(%{"table" => table, "columns" => columns, "identity" => identity},
        pretty: true
      )
    )

    {:ok, path}
  end

  defp read_snapshot(path) do
    case File.read(path) do
      {:ok, json} -> Jason.decode!(json)
      {:error, :enoent} -> nil
    end
  end

  defp snapshot_name(aggregate) do
    aggregate |> inspect() |> Macro.underscore() |> String.replace("/", ".") |> Kernel.<>(".json")
  end

  defp timestamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")

  defp destructive_summary(%{removed: removed, changed: changed}, identity_change) do
    Enum.map(removed, &"remove column #{&1["name"]}") ++
      Enum.map(changed, fn {name, from, to} -> "change #{name} from #{from} to #{to}" end) ++
      case identity_change do
        nil -> []
        {from, to} -> ["change identity from #{inspect(from)} to #{inspect(to)}"]
      end
  end

  # ── Rendering ─────────────────────────────────────────────────────────────

  defp render_create(repo, name, table, columns) do
    adds = Enum.map_join(columns, "\n", &("      " <> add_line(&1)))

    """
    defmodule #{migration_module(repo, name)} do
      use Ecto.Migration

      def change do
        create table(:#{table}, primary_key: false) do
    #{adds}
        end
      end
    end
    """
  end

  defp render_alter(repo, name, table, diff, identity_change) do
    renames =
      for {from, to} <- diff.renamed, do: "    rename table(:#{table}), :#{from}, to: :#{to}"

    alter_lines =
      identity_todo(identity_change) ++
        Enum.map(diff.added, &("      " <> alter_add_line(&1))) ++
        Enum.map(
          diff.removed,
          &"      # DESTRUCTIVE: drops all data in #{&1["name"]}\n      remove :#{&1["name"]}, #{&1["type"]}"
        ) ++
        Enum.map(diff.changed, fn {n, from, to} ->
          "      # DESTRUCTIVE: type change may lose data\n      modify :#{n}, #{to}, from: #{from}"
        end)

    alter =
      if alter_lines == [],
        do: [],
        else: ["    alter table(:#{table}) do\n#{Enum.join(alter_lines, "\n")}\n    end"]

    body = Enum.join(renames ++ alter, "\n\n")

    """
    defmodule #{migration_module(repo, name)} do
      use Ecto.Migration

      def change do
    #{body}
      end
    end
    """
  end

  # The identity changed: every existing row needs its new key, and only you know how the old
  # key maps to it. The generator adds the columns and leaves the key itself to you.
  defp identity_todo(nil), do: []

  defp identity_todo({from, to}) do
    [
      "      # TODO: the identity changed from #{inspect(from)} to #{inspect(to)}.\n" <>
        "      # Backfill the new key for every existing row, then replace the primary key by hand.\n" <>
        "      # The generator never drops the old key."
    ]
  end

  # Adding to a table that has rows: no NOT NULL and no primary key yet (see identity_todo/1).
  defp alter_add_line(%{"name" => name, "type" => type, "primary_key" => true}),
    do: "add :#{name}, #{type}"

  defp alter_add_line(%{"name" => name, "type" => type, "null" => false}),
    do: "add :#{name}, #{type}"

  # The optimistic-locking version: existing rows start at 0.
  defp alter_add_line(%{"name" => "version", "type" => type}),
    do: "add :version, #{type}, null: false, default: 0"

  defp alter_add_line(column), do: add_line(column)

  defp add_line(%{"name" => "version", "type" => type}),
    do: "add :version, #{type}, null: false, default: 0"

  defp add_line(%{"name" => name, "type" => type, "primary_key" => true}),
    do: "add :#{name}, #{type}, primary_key: true"

  defp add_line(%{"name" => name, "type" => type, "null" => false}),
    do: "add :#{name}, #{type}, null: false"

  defp add_line(%{"name" => name, "type" => type}) when name in @timestamp_columns,
    do: "add :#{name}, #{type}, null: false"

  defp add_line(%{"name" => name, "type" => type}), do: "add :#{name}, #{type}"

  defp migration_module(repo, name),
    do: "#{inspect(repo)}.Migrations.#{Macro.camelize(name)}"

  # ── Drift ─────────────────────────────────────────────────────────────────

  @doc """
  Compare an aggregate's columns with the real table. Returns `:ok` or
  `{:error, %{missing_in_db: [...], extra_in_db: [...]}}`.
  """
  @spec drift(module(), String.t(), module()) :: :ok | {:error, map()}
  def drift(aggregate, table, repo) do
    expected = aggregate |> columns() |> Enum.map(& &1["name"])

    case compare(expected, db_columns(repo, table)) do
      {[], []} -> :ok
      {missing, extra} -> {:error, %{missing_in_db: missing, extra_in_db: extra}}
    end
  end

  @doc """
  Compare an aggregate with the Ecto schema you wired it to (`schema:` on `DDD.Repository.Ecto`).
  Report only: nothing is written. Returns `:ok` or
  `{:error, %{missing_in_schema: [...], extra_in_schema: [...]}}`.

  `renames` is `%{"aggregate_field" => "schema_field"}` for the fields your `to_domain/1` and
  `from_domain/1` map by hand. An adapter with a generated schema is always `:ok`.
  """
  @spec schema_drift(module(), %{String.t() => String.t()}) :: :ok | {:error, map()}
  def schema_drift(adapter, renames \\ %{}) do
    case adapter.__ddd_adapter__() do
      %{custom_schema?: true, aggregate: aggregate, schema: schema} ->
        expected =
          aggregate |> columns() |> Enum.map(&Map.get(renames, &1["name"], &1["name"]))

        actual = schema.__schema__(:fields) |> Enum.map(&Atom.to_string/1)

        case compare(expected, actual) do
          {[], []} -> :ok
          {missing, extra} -> {:error, %{missing_in_schema: missing, extra_in_schema: extra}}
        end

      _generated ->
        :ok
    end
  end

  @doc """
  Compare the Ecto schema an adapter was wired to with the real table (`schema:` on
  `DDD.Repository.Ecto`; the table is the schema's). Report only. Returns `:ok` or
  `{:error, %{missing_in_db: [...], extra_in_db: [...]}}`. Needs the database; for a test.
  """
  @spec table_drift(module()) :: :ok | {:error, map()}
  def table_drift(adapter) do
    case adapter.__ddd_adapter__() do
      %{custom_schema?: true, schema: schema, repo: repo} ->
        expected =
          for field <- schema.__schema__(:fields),
              do: Atom.to_string(schema.__schema__(:field_source, field))

        case compare(expected, db_columns(repo, schema.__schema__(:source))) do
          {[], []} -> :ok
          {missing, extra} -> {:error, %{missing_in_db: missing, extra_in_db: extra}}
        end

      _generated ->
        :ok
    end
  end

  @doc """
  The adapter(s) among `modules` that store `aggregate`, as `DDD.Repository.Ecto` records them.
  `mix vic.gen.migration` skips an aggregate whose adapters all use a schema you own.
  """
  @spec custom_schema_adapters(module(), [module()]) :: [map()]
  def custom_schema_adapters(aggregate, modules) do
    for module <- modules,
        Code.ensure_loaded?(module),
        function_exported?(module, :__ddd_adapter__, 0),
        %{aggregate: ^aggregate} = adapter <- [module.__ddd_adapter__()],
        do: Map.put(adapter, :module, module)
  end

  defp db_columns(repo, table),
    do: repo |> DDD.Dialect.for_repo() |> then(& &1.columns(repo, table))

  defp compare(expected, actual) do
    expected = MapSet.new(expected)
    actual = MapSet.new(actual)

    {expected |> MapSet.difference(actual) |> Enum.sort(),
     actual |> MapSet.difference(expected) |> Enum.sort()}
  end
end
