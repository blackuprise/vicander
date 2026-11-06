defmodule DDD.Outbox.Event do
  @moduledoc """
  A row of the `domain_events` outbox table (see `mix vic.gen.outbox_migration`).

  An Ecto schema so that the framework's queries run on any adapter: the adapter dumps ids and
  timestamps, and the framework writes no SQL of its own for them. `id` is the UUID string.
  """
  use Ecto.Schema
  require Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "domain_events" do
    field(:event_type, :string)
    field(:aggregate_id, :string)
    field(:aggregate_type, :string)
    # Any JSON term, not only an object: a row that was damaged by hand must load, so that the
    # one event fails (see `DDD.Outbox.Poller.build_event/1`) instead of the whole batch.
    field(:payload, DDD.Type.Json)
    field(:occurred_at, :utc_datetime_usec)
    field(:published_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:locked_until, :utc_datetime_usec)
    field(:failed_at, :utc_datetime_usec)
    field(:resolution, :string)
    field(:resolved_at, :utc_datetime_usec)
    field(:replays, :integer, default: 0)
    field(:inserted_at, :naive_datetime)
  end

  @doc "The fields of an event as the poller and the projections read them."
  def delivery_fields,
    do: [:id, :event_type, :aggregate_id, :aggregate_type, :payload, :occurred_at, :attempts]

  @doc false
  # Reserve rows for `lease_ms`: select `fields` of the rows `due.(now)` finds (the query
  # orders and limits them; its own select is replaced), locking them with the dialect's lock
  # clause so another node skips them, then mark them leased. `inc` is added to counters in the
  # same update, and to the rows returned, so they show what was stored. Two statements and no
  # `UPDATE … RETURNING`, which not every database has.
  def claim(repo, lease_ms, fields, inc, due) do
    dialect = DDD.Dialect.for_repo(repo)
    fields = Enum.uniq([:id | fields])

    {:ok, rows} =
      repo.transaction(fn ->
        now = dialect.now(repo)

        query =
          now
          |> due.()
          |> Ecto.Query.exclude(:select)
          |> Ecto.Query.select([e], map(e, ^fields))
          |> dialect.lock_for_claim()

        case repo.all(query) do
          [] ->
            []

          rows ->
            ids = Enum.map(rows, & &1.id)
            leased_until = DateTime.add(now, lease_ms, :millisecond)

            Ecto.Query.from(e in __MODULE__, where: e.id in ^ids)
            |> repo.update_all(set: [locked_until: leased_until], inc: inc)

            Enum.map(rows, &increment(&1, inc))
        end
      end)

    rows
  end

  defp increment(row, inc) do
    Enum.reduce(inc, row, fn {field, by}, acc ->
      if Map.has_key?(acc, field), do: Map.update!(acc, field, &((&1 || 0) + by)), else: acc
    end)
  end
end
