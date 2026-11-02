defmodule Mix.Tasks.Vic.Outbox.Replay do
  @shortdoc "Replays dead-lettered outbox events"
  @moduledoc """
  Makes the outbox retry dead-lettered events from scratch.

      mix vic.outbox.replay EVENT_ID     # one event
      mix vic.outbox.replay --all        # every unresolved dead letter

  Handlers that already succeeded for the event are skipped, so only the ones that failed run
  again. Fix the cause first, otherwise the event just dies again.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, ids, _} = OptionParser.parse(args, strict: [all: :boolean, repo: :string])
    Mix.Task.run("app.start")
    repo = Mix.Tasks.Vic.Outbox.DeadLetters.repo(opts)

    cond do
      opts[:all] ->
        count = DDD.Outbox.DeadLetters.replay_all(repo)
        Mix.shell().info("Replaying #{count} dead letter(s).")

      ids == [] ->
        Mix.raise("usage: mix vic.outbox.replay EVENT_ID | --all")

      true ->
        Enum.each(ids, fn id ->
          case DDD.Outbox.DeadLetters.replay(repo, id) do
            :ok -> Mix.shell().info("Replaying #{id}.")
            {:error, :not_found} -> Mix.raise("#{id} is not a dead letter")
          end
        end)
    end
  end
end
