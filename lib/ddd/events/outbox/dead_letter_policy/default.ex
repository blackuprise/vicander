defmodule DDD.Outbox.DeadLetterPolicy.Default do
  @moduledoc """
  The recommended default: **keep** every dead letter. The failure has already been logged at
  error level and emitted as a `[:ddd, :outbox, :dead_letter]` telemetry event, so someone
  looks at it and replays it by hand (`mix vic.outbox.replay`).

  A dead letter means a handler failed repeatedly, usually because of a bug or bad data, so
  replaying it automatically before anyone has looked at it mostly repeats the failure.
  Automatic replay is opt-in, for transient causes such as an outage longer than the retries:

      config :vicander, :dead_letters,
        max_replays: 3,             # replay each dead letter at most this many times (default 0)
        replay_cooldown_ms: 60_000  # wait this long after it died before replaying (default 1 min)

  After `max_replays` replays it is kept.
  """
  @behaviour DDD.Outbox.DeadLetterPolicy

  @impl true
  def handle(dead_letter) do
    config = Application.get_env(:vicander, :dead_letters, [])
    max_replays = Keyword.get(config, :max_replays, 0)
    cooldown_ms = Keyword.get(config, :replay_cooldown_ms, 60_000)
    waited_ms = DateTime.diff(DateTime.utc_now(), dead_letter.failed_at, :millisecond)

    cond do
      dead_letter.replays >= max_replays -> :keep
      waited_ms < cooldown_ms -> :later
      true -> :replay
    end
  end
end
