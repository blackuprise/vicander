defmodule Mix.Tasks.Vic.Gen.Migration do
  @shortdoc "Generates (or diffs) the table migration for an aggregate"
  @moduledoc """
  Generates the Ecto migration for an aggregate stored by `DDD.Repository.Ecto`.

      mix vic.gen.migration MyApp.Order
      mix vic.gen.migration MyApp.Order --rename title:name
      mix vic.gen.migration MyApp.Order --allow-destructive

  The first run writes `create table`. Later runs compare the aggregate with the
  snapshot in `priv/ddd_snapshots/` and write only the difference as a new migration.

  Options:

    * `--table`             - table name (first run only; default derived from the module)
    * `--rename old:new`    - treat a column as renamed, keeping its data (repeatable)
    * `--allow-destructive` - allow removing a column or changing its type
    * `--repo`              - repo module for the migration name (default: the configured repo)
    * `--snapshot-dir`, `--migrations-path` - override the default directories
  """

  use Mix.Task

  @switches [
    table: :string,
    rename: [:string, :keep],
    allow_destructive: :boolean,
    repo: :string,
    snapshot_dir: :string,
    migrations_path: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    {opts, modules, _} = OptionParser.parse(args, strict: @switches)

    if modules == [], do: Mix.raise("usage: mix vic.gen.migration <AggregateModule>")

    base = DateTime.utc_now()

    modules
    |> Enum.with_index()
    |> Enum.each(fn {name, index} ->
      aggregate = Module.concat([name])
      # One second apart: Ecto rejects two migrations with the same version.
      timestamp = base |> DateTime.add(index, :second) |> Calendar.strftime("%Y%m%d%H%M%S")

      unless Code.ensure_loaded?(aggregate) and function_exported?(aggregate, :__ddd_fields__, 0) do
        Mix.raise("#{name} is not a DDD aggregate or entity")
      end

      case custom_schema_only(aggregate) do
        [] -> generate(name, aggregate, timestamp, opts)
        adapters -> skip(name, adapters)
      end
    end)
  end

  defp generate(name, aggregate, timestamp, opts) do
    case DDD.Migration.generate(aggregate, [{:timestamp, timestamp} | generate_opts(opts)]) do
      {:ok, :unchanged} ->
        Mix.shell().info("#{name}: no changes")

      {:ok, path} ->
        Mix.shell().info([:green, "* created ", :reset, path])

      {:error, {:destructive, changes}} ->
        Mix.raise(
          "#{name}: destructive changes (#{Enum.join(changes, "; ")}). " <>
            "Use --rename old:new to keep data, or --allow-destructive to proceed."
        )
    end
  end

  # The table of an aggregate stored through a schema you own is yours: no migration for it.
  defp skip(name, adapters) do
    schemas = adapters |> Enum.map_join(", ", &inspect(&1.schema))

    Mix.shell().info(
      "#{name}: skipped, stored through your own schema (#{schemas}); you own the table. " <>
        "Check it with DDD.Migration.schema_drift/1 and DDD.Migration.table_drift/1 in a test."
    )
  end

  # The adapters of `aggregate` when every one of them uses a schema you own, else `[]`.
  defp custom_schema_only(aggregate) do
    adapters = DDD.Migration.custom_schema_adapters(aggregate, candidate_modules())

    if adapters != [] and Enum.all?(adapters, & &1.custom_schema?), do: adapters, else: []
  end

  defp candidate_modules do
    app_modules =
      with app when not is_nil(app) <- Mix.Project.config()[:app],
           _ <- Application.load(app),
           modules when is_list(modules) <- Application.spec(app, :modules) do
        modules
      else
        _ -> []
      end

    loaded = for {module, _} <- :code.all_loaded(), do: module
    Enum.uniq(app_modules ++ loaded)
  end

  @doc false
  def generate_opts(opts) do
    renames =
      opts
      |> Keyword.get_values(:rename)
      |> Map.new(fn pair ->
        case String.split(pair, ":", parts: 2) do
          [old, new] -> {old, new}
          _ -> Mix.raise("--rename expects old:new, got #{inspect(pair)}")
        end
      end)

    opts
    |> Keyword.delete(:rename)
    |> Keyword.update(:repo, nil, &Module.concat([&1]))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.put(:renames, renames)
  end
end
