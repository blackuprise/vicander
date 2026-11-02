defmodule DDD.Outbox.DeadLetters do
  @moduledoc """
  Inspect and resolve dead-lettered outbox events.

  An event is dead-lettered when delivery kept failing (an infrastructure error, an exception,
  an event type that can't be resolved) and the poller ran out of retries. Business rejections
  are *not* dead letters: they are recorded as `rejected` in `event_deliveries`.

  A dead letter is *unresolved* until someone decides what to do with it:

    * `replay/2`  - clear the failure state; the poller retries it. Handlers that already
      succeeded for the event are skipped.
    * `keep/2`    - acknowledge it and leave it dead-lettered (nothing more will happen).
    * `discard/2` - drop it for good.

  `DDD.Outbox.DeadLetterHandler` applies a policy to new dead letters automatically; the
  `mix vic.outbox.*` tasks call these functions for manual work.
  """

  import Ecto.Query

  alias DDD.Outbox.Event

  @fields [
    :id,
    :event_type,
    :aggregate_type,
    :aggregate_id,
    :payload,
    :attempts,
    :last_error,
    :failed_at,
    :resolution,
    :resolved_at,
    :replays
  ]

  @type dead_letter :: %{
          id: String.t(),
          event_type: String.t(),
          aggregate_type: String.t(),
          aggregate_id: String.t(),
          payload: map(),
          attempts: non_neg_integer(),
          last_error: String.t() | nil,
          failed_at: DateTime.t(),
          resolution: String.t() | nil,
          resolved_at: DateTime.t() | nil,
          replays: non_neg_integer()
        }

  @doc """
  Dead letters, oldest first. Only unresolved ones unless `all: true`. `limit:` defaults to 100.
  """
  @spec list(module(), keyword()) :: [dead_letter()]
  def list(repo, opts \\ []) do
    query =
      from(e in Event,
        where: not is_nil(e.failed_at),
        order_by: e.failed_at,
        limit: ^Keyword.get(opts, :limit, 100),
        select: map(e, ^@fields)
      )

    query =
      if Keyword.get(opts, :all, false), do: query, else: where(query, [e], is_nil(e.resolved_at))

    repo.all(query)
  end

  @doc "One dead letter by its UUID string, or `nil`."
  @spec get(module(), String.t()) :: dead_letter() | nil
  def get(repo, id) do
    repo.one(
      from(e in Event,
        where: e.id == type(^id, :binary_id) and not is_nil(e.failed_at),
        select: map(e, ^@fields)
      )
    )
  end

  @doc "Make the poller retry the event from scratch. Counts in `replays`."
  @spec replay(module(), String.t()) :: :ok | {:error, :not_found}
  def replay(repo, id) do
    change(
      repo,
      id,
      [
        set: [
          failed_at: nil,
          attempts: 0,
          next_attempt_at: nil,
          locked_until: nil,
          resolution: nil,
          resolved_at: nil
        ],
        inc: [replays: 1]
      ],
      dead_letter?: true
    )
  end

  @doc "Replay every unresolved dead letter. Returns how many were replayed."
  @spec replay_all(module()) :: non_neg_integer()
  def replay_all(repo) do
    repo
    |> list(limit: 10_000)
    |> Enum.count(&(replay(repo, &1.id) == :ok))
  end

  @doc "Acknowledge the dead letter and leave it as it is."
  @spec keep(module(), String.t()) :: :ok | {:error, :not_found}
  def keep(repo, id), do: resolve(repo, id, "kept")

  @doc "Resolve the dead letter as discarded."
  @spec discard(module(), String.t()) :: :ok | {:error, :not_found}
  def discard(repo, id), do: resolve(repo, id, "discarded")

  @doc false
  # Reserve unresolved dead letters for `lease_ms` so two nodes don't handle the same one.
  def claim_unresolved(repo, limit, lease_ms) do
    Event.claim(repo, lease_ms, [asc: :failed_at], @fields, [], fn now ->
      from(e in Event,
        where:
          not is_nil(e.failed_at) and is_nil(e.resolved_at) and
            (is_nil(e.locked_until) or e.locked_until <= ^now),
        order_by: e.failed_at,
        limit: ^limit,
        select: e.id
      )
    end)
  end

  @doc false
  # Give a claimed dead letter back (it stays unresolved and is looked at again later).
  def release(repo, id), do: change(repo, id, set: [locked_until: nil])

  defp resolve(repo, id, resolution) do
    change(
      repo,
      id,
      [
        set: [
          resolution: resolution,
          resolved_at: DDD.Dialect.usec(DateTime.utc_now()),
          locked_until: nil
        ]
      ],
      dead_letter?: true
    )
  end

  defp change(repo, id, updates, opts \\ []) do
    query = from(e in Event, where: e.id == type(^id, :binary_id))
    query = if opts[:dead_letter?], do: where(query, [e], not is_nil(e.failed_at)), else: query

    case repo.update_all(query, updates) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end
end
