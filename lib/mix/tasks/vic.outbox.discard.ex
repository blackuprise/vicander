defmodule Mix.Tasks.Vic.Outbox.Discard do
  @shortdoc "Discards a dead-lettered outbox event"
  @moduledoc """
  Resolves a dead-lettered event as discarded: it stays in the table for the record, but
  nothing will deliver it.

      mix vic.outbox.discard EVENT_ID
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, ids, _} = OptionParser.parse(args, strict: [repo: :string])
    Mix.Task.run("app.start")
    repo = Mix.Tasks.Vic.Outbox.DeadLetters.repo(opts)

    if ids == [], do: Mix.raise("usage: mix vic.outbox.discard EVENT_ID")

    Enum.each(ids, fn id ->
      case DDD.Outbox.DeadLetters.discard(repo, id) do
        :ok -> Mix.shell().info("Discarded #{id}.")
        {:error, :not_found} -> Mix.raise("#{id} is not a dead letter")
      end
    end)
  end
end
