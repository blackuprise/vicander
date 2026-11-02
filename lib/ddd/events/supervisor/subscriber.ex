defmodule DDD.Supervisor.Subscriber do
  @moduledoc false
  # Subscribes the handlers to the event bus, once, then ends. Under `DDD.Supervisor`'s
  # `:rest_for_one` strategy it runs again whenever the bus restarts.
  use Task, restart: :transient

  def start_link(handlers), do: Task.start_link(__MODULE__, :run, [handlers])

  def run(handlers), do: Enum.each(handlers, & &1.subscribe())
end
