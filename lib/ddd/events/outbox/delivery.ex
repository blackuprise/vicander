defmodule DDD.Outbox.Delivery do
  @moduledoc """
  A row of `event_deliveries`: which handler already processed which event, and how.
  """
  use Ecto.Schema

  @primary_key false
  schema "event_deliveries" do
    field(:event_id, :binary_id)
    field(:handler, :string)
    field(:outcome, :string)
    field(:reason, :string)
    field(:delivered_at, :utc_datetime_usec)
  end
end
