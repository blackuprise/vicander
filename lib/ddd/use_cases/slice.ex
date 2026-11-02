defmodule DDD.Slice do
  @moduledoc """
  A window of a listing that continues from a cursor (keyset pagination). Returned by `slice/1`
  on repository adapters and projections:

      {:ok, slice} = ListSummary.slice(order: [asc: :title], limit: 20)
      {:ok, next} = ListSummary.slice(order: [asc: :title], limit: 20, after: slice.next_cursor)

  There is no `OFFSET`, so page 500 costs the same as page 1, and rows added or removed while
  someone pages through don't shift what they see. `next_cursor` is `nil` on the last slice. A
  cursor is opaque: it is only valid with the `:order` it came from, and the order's fields
  should not be `NULL` (the primary key is always added as the last tie-breaker).
  """

  defstruct entries: [], next_cursor: nil, limit: 20

  @type t :: %__MODULE__{entries: [term()], next_cursor: String.t() | nil, limit: pos_integer()}

  @doc "True when there is a slice after this one."
  @spec has_next?(t()) :: boolean()
  def has_next?(%__MODULE__{next_cursor: cursor}), do: not is_nil(cursor)
end
