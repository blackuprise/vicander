defmodule DDD.Page do
  @moduledoc """
  One numbered page of a listing, with the totals. Returned by `page/1` on repository adapters
  and projections:

      {:ok, %DDD.Page{entries: lists, page: 2, page_size: 20, total_entries: 57, total_pages: 3}} =
        TodoListRepository.page(filter: [owner_id: id], order: [desc: :created_at], page: 2)

  Counting makes this one extra query. For long or hot listings prefer `DDD.Slice`, which has no
  totals and doesn't slow down on deep pages.
  """

  defstruct entries: [], page: 1, page_size: 20, total_entries: 0, total_pages: 0

  @type t :: %__MODULE__{
          entries: [term()],
          page: pos_integer(),
          page_size: pos_integer(),
          total_entries: non_neg_integer(),
          total_pages: non_neg_integer()
        }

  @doc "True when a later page exists."
  @spec has_next?(t()) :: boolean()
  def has_next?(%__MODULE__{page: page, total_pages: total}), do: page < total

  @doc "True when an earlier page exists."
  @spec has_previous?(t()) :: boolean()
  def has_previous?(%__MODULE__{page: page}), do: page > 1
end
