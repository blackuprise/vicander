defmodule DDD.Outbox.Retention do
  @moduledoc """
  Deleting old events from the outbox, so `domain_events` doesn't grow forever.

      DDD.Outbox.Retention.prune(MyApp.Repo, older_than_days: 30)
      # => {:ok, %{deleted: 1204}}

  Or from the command line: `mix vic.outbox.prune --older-than-days 30`. To prune on a schedule,
  give the supervisor `retention: [older_than_days: 30]` (see `DDD.Supervisor`) or call
  `prune/2` from your own scheduler.

  What is deleted, once it is older than the limit:

    * events that were **published** (every handler succeeded or rejected them), together with
      their delivery records
    * dead letters that were **resolved** (discarded or replayed)

  What is never deleted: events still waiting, events being retried, and dead letters nobody has
  resolved.

  **Pruning is a choice with a cost.** A projection's `rebuild/0` replays the events in this
  table; once the old ones are gone, a rebuild can only rebuild from what is left. Prune after
  the longest history you are willing to rebuild from, or archive the table first.
  """

  @batch 5_000

  import Ecto.Query

  alias DDD.Outbox.Event

  @doc """
  Delete old events. Options:

    * `:older_than_days` - (required) how old, in days, an event must be. There is no default:
      deleting is not something to do by accident.
    * `:batch` - rows deleted per statement (default #{@batch}), so a big backlog doesn't hold
      long locks

  Returns `{:ok, %{deleted: count}}`.
  """
  @spec prune(module(), keyword()) :: {:ok, %{deleted: non_neg_integer()}}
  def prune(repo, opts) do
    days = Keyword.fetch!(opts, :older_than_days)

    unless is_integer(days) and days > 0 do
      raise ArgumentError, ":older_than_days must be a positive integer, got: #{inspect(days)}"
    end

    batch = Keyword.get(opts, :batch, @batch)

    cutoff =
      DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DDD.Dialect.usec()

    {:ok, %{deleted: delete_in_batches(repo, cutoff, batch, 0)}}
  end

  # Ids first, then the delete by id: `DELETE … WHERE id IN (SELECT … LIMIT n)` is refused by
  # some databases (MySQL), and this runs on all of them.
  defp delete_in_batches(repo, cutoff, batch, total) do
    ids =
      repo.all(
        from(e in Event,
          where:
            (not is_nil(e.published_at) and e.published_at < ^cutoff) or
              (not is_nil(e.resolved_at) and e.resolved_at < ^cutoff),
          limit: ^batch,
          select: e.id
        )
      )

    {deleted, _} = repo.delete_all(from(e in Event, where: e.id in ^ids))

    if deleted < batch,
      do: total + deleted,
      else: delete_in_batches(repo, cutoff, batch, total + deleted)
  end
end
