defmodule DDD.Health.Query do
  @moduledoc """
  `DDD.Health.check/0` as a `DDD.Query`, so it can be listed in an MCP server (or anywhere a
  query is accepted):

      use DDD.MCP.Server, queries: [DDD.Health.Query, ...]

  Which projections are checked, and the thresholds, come from `config :vicander, :health`.
  """
  use DDD.Query, transaction: false

  query do
    description(
      "Health of the database, the outbox and the projections (ok, degraded, unhealthy)"
    )
  end

  @impl DDD.Query
  def execute(_query), do: {:ok, DDD.Health.check()}
end
