defmodule Mix.Tasks.Vic.Health do
  @shortdoc "Checks the database, the outbox and the projections"
  @moduledoc """
  Prints `DDD.Health.check/1` and exits non-zero unless everything is `ok`, so it can run as a
  deploy gate or a container health probe.

      mix vic.health
      mix vic.health --json
      mix vic.health --projection MyApp.Projections.ListSummary --max-outbox-age 5000

  Options:

    * `--json` - print the result as JSON
    * `--projection Module` - check a projection (repeatable; adds to the configured ones)
    * `--max-outbox-age ms`, `--max-dead-letters n`, `--max-projection-lag ms` - thresholds
    * `--repo Module` - default: the configured repo (`config :vicander, repo: MyApp.Repo`)
  """

  use Mix.Task

  @switches [
    json: :boolean,
    projection: [:string, :keep],
    max_outbox_age: :integer,
    max_dead_letters: :integer,
    max_projection_lag: :integer,
    repo: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.start")

    result = DDD.Health.check(health_opts(opts))

    if opts[:json],
      do: Mix.shell().info(Jason.encode!(result, pretty: true)),
      else: print(result)

    if result.status != :ok, do: exit({:shutdown, 1})
    result
  end

  @doc false
  def health_opts(opts) do
    configured = Application.get_env(:vicander, :health, [])[:projections] || []
    given = opts |> Keyword.get_values(:projection) |> Enum.map(&Module.concat([&1]))

    [
      projections: Enum.uniq(configured ++ given),
      max_outbox_age_ms: opts[:max_outbox_age],
      max_dead_letters: opts[:max_dead_letters],
      max_projection_lag_ms: opts[:max_projection_lag],
      repo: opts[:repo] && Module.concat([opts[:repo]])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp print(%{status: status, checks: checks}) do
    Mix.shell().info("status: #{status}")
    Mix.shell().info("database:   #{line(checks.database)}")
    if checks.outbox, do: Mix.shell().info("outbox:     #{line(checks.outbox)}")

    for {name, check} <- Enum.sort(checks.projections) do
      Mix.shell().info("projection #{name}: #{line(check)}")
    end
  end

  defp line(check) do
    details =
      check
      |> Map.drop([:status, :problems, :error])
      |> Enum.sort()
      |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)

    problems = (check[:problems] || []) ++ List.wrap(check[:error])
    base = "#{check.status}" <> if(details == "", do: "", else: " (#{details})")
    if problems == [], do: base, else: base <> " - " <> Enum.join(problems, "; ")
  end
end
