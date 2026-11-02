defmodule DDD.Outbox.DeadLetterHandler do
  @moduledoc """
  A supervised process that applies a `DDD.Outbox.DeadLetterPolicy` to dead-lettered events.

  The database is the source of truth. The poller sends this process a best-effort `notify/0`
  when it gives up on an event, but a message can be lost if the process is down. So the
  process also sweeps for unresolved dead letters when it (re)starts and then periodically.
  If it crashes and restarts, nothing is lost: unresolved dead letters are simply found again.

  Dead letters are claimed with a lease and `FOR UPDATE SKIP LOCKED`, so with several nodes each
  dead letter is handled once.

  ## Options

    * `:repo`              - (required) your Ecto.Repo
    * `:policy`            - a `DDD.Outbox.DeadLetterPolicy` module (default
      `DDD.Outbox.DeadLetterPolicy.Default`, which keeps everything)
    * `:sweep_interval_ms` - how often to sweep (default 60_000)
    * `:batch_size`        - dead letters per sweep (default 50)
    * `:lease_ms`          - how long a claimed dead letter is reserved (default 30_000)

  Each can also be set under `config :vicander, :dead_letters`; an option passed here wins.
  """

  use GenServer
  require Logger

  alias DDD.Outbox.DeadLetters

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Ask the handler to sweep now. A no-op when the process is not running."
  def notify, do: GenServer.cast(__MODULE__, :sweep)

  @doc "Sweep now and return how many dead letters were handled (useful in tests)."
  def sweep_now, do: GenServer.call(__MODULE__, :sweep, 30_000)

  @impl GenServer
  def init(opts) do
    env = Application.get_env(:vicander, :dead_letters, [])
    get = fn key, default -> Keyword.get(opts, key, Keyword.get(env, key, default)) end

    state = %{
      repo: Keyword.fetch!(opts, :repo),
      policy: get.(:policy, DDD.Outbox.DeadLetterPolicy.Default),
      sweep_interval_ms: get.(:sweep_interval_ms, 60_000),
      batch_size: get.(:batch_size, 50),
      lease_ms: get.(:lease_ms, 30_000)
    }

    # Let a shutdown finish the current sweep instead of killing it mid-query.
    Process.flag(:trap_exit, true)

    # Pick up whatever was dead-lettered while this process was down.
    send(self(), :tick)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    sweep(state)
    Process.send_after(self(), :tick, state.sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast(:sweep, state) do
    sweep(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:sweep, _from, state), do: {:reply, {:ok, sweep(state)}, state}

  defp sweep(state) do
    dead_letters = DeadLetters.claim_unresolved(state.repo, state.batch_size, state.lease_ms)
    Enum.each(dead_letters, &resolve(&1, state))
    length(dead_letters)
  end

  defp resolve(dead_letter, state) do
    case decide(state.policy, dead_letter) do
      :keep ->
        DeadLetters.keep(state.repo, dead_letter.id)
        log(:info, dead_letter, "kept (needs a person: mix vic.outbox.replay #{dead_letter.id})")

      :discard ->
        DeadLetters.discard(state.repo, dead_letter.id)
        log(:warning, dead_letter, "discarded")

      :replay ->
        DeadLetters.replay(state.repo, dead_letter.id)
        log(:info, dead_letter, "replayed automatically (replay #{dead_letter.replays + 1})")

      :later ->
        DeadLetters.release(state.repo, dead_letter.id)
    end
  end

  defp decide(policy, dead_letter) do
    case policy.handle(dead_letter) do
      decision when decision in [:keep, :replay, :discard, :later] ->
        decision

      other ->
        Logger.error(
          "[dead_letter] #{inspect(policy)} returned #{inspect(other)}; deciding later"
        )

        :later
    end
  rescue
    exception ->
      Logger.error("[dead_letter] #{inspect(policy)} raised: #{Exception.message(exception)}")
      :later
  end

  defp log(level, dead_letter, what) do
    Logger.log(
      level,
      "[dead_letter] #{dead_letter.event_type} (#{dead_letter.aggregate_type} " <>
        "#{dead_letter.aggregate_id}) #{what}; last error: #{dead_letter.last_error}"
    )
  end
end
