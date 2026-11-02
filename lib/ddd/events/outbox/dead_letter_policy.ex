defmodule DDD.Outbox.DeadLetterPolicy do
  @moduledoc """
  Decides what to do with a dead-lettered event.

      defmodule MyApp.DeadLetterPolicy do
        @behaviour DDD.Outbox.DeadLetterPolicy

        @impl true
        def handle(%{event_type: "MyApp.Events.OrderPlaced"}), do: :replay
        def handle(_dead_letter), do: :keep
      end

  `handle/1` receives a map with `:id`, `:event_type`, `:aggregate_type`, `:aggregate_id`,
  `:payload`, `:attempts`, `:last_error`, `:failed_at` and `:replays`, and returns:

    * `:keep`    - acknowledge it and leave it dead-lettered
    * `:replay`  - make the poller retry it from scratch
    * `:discard` - resolve it as discarded
    * `:later`   - decide on a later sweep (it stays unresolved)

  A policy that raises is logged and treated as `:later`, so it can never crash the handler.
  """

  @callback handle(dead_letter :: map()) :: :keep | :replay | :discard | :later
end
