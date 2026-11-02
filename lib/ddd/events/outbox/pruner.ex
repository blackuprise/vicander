defmodule DDD.Outbox.Pruner do
  @moduledoc """
  Prunes the outbox on a timer (`DDD.Outbox.Retention`). Started by `DDD.Supervisor` when it is
  given `retention: [older_than_days: 30]`; `:every_ms` sets how often (default: hourly).
  """
  use GenServer
  require Logger

  @default_every_ms 3_600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Prune now and return the result (useful in tests)."
  def prune_now, do: GenServer.call(__MODULE__, :prune, 60_000)

  @impl GenServer
  def init(opts) do
    state = %{
      repo: Keyword.fetch!(opts, :repo),
      days: Keyword.fetch!(opts, :older_than_days),
      every_ms: Keyword.get(opts, :every_ms, @default_every_ms)
    }

    schedule(state.every_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    run(state)
    schedule(state.every_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:prune, _from, state), do: {:reply, run(state), state}

  defp run(state) do
    {:ok, %{deleted: deleted}} =
      DDD.Outbox.Retention.prune(state.repo, older_than_days: state.days)

    if deleted > 0,
      do: Logger.info("[outbox] pruned #{deleted} event(s) older than #{state.days} day(s)")

    {:ok, %{deleted: deleted}}
  end

  defp schedule(ms), do: Process.send_after(self(), :prune, ms)
end
