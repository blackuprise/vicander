defmodule Mix.Tasks.Vic.Outbox.Prune do
  @shortdoc "Deletes old published events from the outbox"
  @moduledoc """
  Deletes events older than a number of days from the outbox (`DDD.Outbox.Retention`).

      mix vic.outbox.prune --older-than-days 30

  Only published events and resolved dead letters are deleted. Unresolved dead letters, events
  being retried and events still waiting are kept. A projection can only be rebuilt from the
  events that remain.

  Options:

    * `--older-than-days n` - (required) how old an event must be
    * `--repo Module` - default: the configured repo
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [older_than_days: :integer, repo: :string])

    days = opts[:older_than_days] || Mix.raise("usage: mix vic.outbox.prune --older-than-days N")
    if days < 1, do: Mix.raise("--older-than-days must be at least 1")

    Mix.Task.run("app.start")
    repo = Mix.Tasks.Vic.Outbox.DeadLetters.repo(opts)

    {:ok, %{deleted: deleted}} = DDD.Outbox.Retention.prune(repo, older_than_days: days)
    Mix.shell().info("pruned #{deleted} event(s) older than #{days} day(s)")
  end
end
