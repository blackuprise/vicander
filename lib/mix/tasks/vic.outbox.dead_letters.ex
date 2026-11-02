defmodule Mix.Tasks.Vic.Outbox.DeadLetters do
  @shortdoc "Lists dead-lettered outbox events"
  @moduledoc """
  Lists events the outbox gave up delivering (infrastructure failures that kept recurring).

      mix vic.outbox.dead_letters            # unresolved ones
      mix vic.outbox.dead_letters --all      # include kept and discarded ones

  Resolve them with `mix vic.outbox.replay ID` or `mix vic.outbox.discard ID`.
  Business rejections are not dead letters; they are recorded in `event_deliveries`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [all: :boolean, repo: :string, limit: :integer])

    Mix.Task.run("app.start")
    repo = repo(opts)

    case DDD.Outbox.DeadLetters.list(repo, Keyword.take(opts, [:all, :limit])) do
      [] ->
        Mix.shell().info("No dead letters.")

      dead_letters ->
        Enum.each(dead_letters, &print/1)
        Mix.shell().info("#{length(dead_letters)} dead letter(s)")
    end
  end

  defp print(dead_letter) do
    status = dead_letter.resolution || "unresolved"

    Mix.shell().info("""
    #{dead_letter.id}  [#{status}]
      #{dead_letter.event_type} (#{dead_letter.aggregate_type} #{dead_letter.aggregate_id})
      failed #{DateTime.to_iso8601(dead_letter.failed_at)} after #{dead_letter.attempts} attempt(s), \
    replayed #{dead_letter.replays}x
      #{dead_letter.last_error}
    """)
  end

  @doc false
  def repo(opts) do
    case Keyword.get(opts, :repo) do
      nil -> DDD.Config.repo!()
      name -> Module.concat([name])
    end
  end
end
