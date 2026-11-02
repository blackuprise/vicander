defmodule Mix.Tasks.Vic.Projection.Rebuild do
  @shortdoc "Rebuilds projections by replaying the stored events"
  @moduledoc """
  Empties a projection's table and replays every stored event into it, in order.

      mix vic.projection.rebuild MyApp.Projections.ListSummary
      mix vic.projection.rebuild MyApp.Projections.ListSummary MyApp.Projections.Other

  Use it after fixing an `on` clause, or after adding a projection for events that already
  happened. The events must still be in `domain_events`. Readers see the table fill up again
  while it runs, so run it in a quiet period; if it fails part-way the projection is partial
  and the task says so and exits non-zero: fix the cause and run it again.

  Each projection is rebuilt on its own: a failure in one does not stop the others.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {_opts, modules, _} = OptionParser.parse(args, strict: [])
    if modules == [], do: Mix.raise("usage: mix vic.projection.rebuild <ProjectionModule> ...")

    Mix.Task.run("app.start")

    failed =
      for name <- modules, not rebuild(Module.concat([name])) do
        name
      end

    if failed != [], do: Mix.raise("could not rebuild: #{Enum.join(failed, ", ")}")
    :ok
  end

  defp rebuild(projection) do
    if Code.ensure_loaded?(projection) and function_exported?(projection, :rebuild, 0) do
      case projection.rebuild() do
        {:ok, %{events: events}} ->
          Mix.shell().info("#{inspect(projection)}: replayed #{events} event(s)")
          true

        {:error, %DDD.Error{} = error} ->
          Mix.shell().error("#{inspect(projection)}: #{error.message}")
          false
      end
    else
      Mix.shell().error("#{inspect(projection)} is not a DDD.Projection")
      false
    end
  end
end
