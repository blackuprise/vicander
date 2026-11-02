defmodule DDD.Listing do
  @moduledoc """
  The listing functions shared by repository adapters (`DDD.Repository.Ecto`) and projections
  (`DDD.Projection`): `list/1`, `page/1`, `slice/1` and `count/1`.

  Options (all optional):

    * `:filter` - a `DDD.Filter` expression
    * `:spec` - a `DDD.Specification` (one that defines `to_filter/1`); combined with `:filter`
    * `:order` - `:title`, `{:desc, :title}` or `[desc: :created_at, asc: :title]`. The primary
      key is always added as the last tie-breaker, so the order is total and pages are stable.
      Default: the primary key.
    * `list/1`: `:limit` (default: all)
    * `page/1`: `:page` (default 1), `:page_size` (default 20, at most 1000)
    * `slice/1`: `:limit` (default 20, at most 1000), `:after` (a `DDD.Slice`'s `next_cursor`)

  Everything returns `{:ok, result}` or `{:error, %DDD.Error{kind: :business}}` with the code
  `:invalid_filter`, `:invalid_order`, `:invalid_page` or `:invalid_cursor`: these options often
  come straight from a client's request, so a bad one is an answer, not a crash.
  """

  import Ecto.Query

  @max_page_size 1000
  @default_page_size 20

  @typedoc false
  # repo: the Ecto repo; schema: the Ecto schema module; types: %{field => domain type};
  # pk: the primary key field; map: converts a loaded record to what the caller gets back.
  @type ctx :: %{
          repo: module(),
          schema: module(),
          types: map(),
          pk: atom(),
          map: (term() -> term())
        }

  @spec list(ctx(), keyword()) :: {:ok, [term()]} | {:error, DDD.Error.t()}
  def list(ctx, opts) do
    guarded(fn ->
      with {:ok, query} <- filtered(ctx, opts),
           {:ok, order} <- normalize_order(ctx, opts[:order]),
           {:ok, limit} <- size_option(opts[:limit], nil) do
        query = query |> order_by(^order) |> maybe_limit(limit)
        {:ok, query |> ctx.repo.all() |> Enum.map(ctx.map)}
      end
    end)
  end

  @spec count(ctx(), keyword()) :: {:ok, non_neg_integer()} | {:error, DDD.Error.t()}
  def count(ctx, opts) do
    guarded(fn ->
      with {:ok, query} <- filtered(ctx, opts), do: {:ok, ctx.repo.aggregate(query, :count)}
    end)
  end

  @spec page(ctx(), keyword()) :: {:ok, DDD.Page.t()} | {:error, DDD.Error.t()}
  def page(ctx, opts) do
    guarded(fn ->
      with {:ok, query} <- filtered(ctx, opts),
           {:ok, order} <- normalize_order(ctx, opts[:order]),
           {:ok, number} <- positive(opts[:page], 1, :page),
           {:ok, size} <- size_option(opts[:page_size], @default_page_size) do
        total = ctx.repo.aggregate(query, :count)

        entries =
          query
          |> order_by(^order)
          |> limit(^size)
          |> offset(^((number - 1) * size))
          |> ctx.repo.all()
          |> Enum.map(ctx.map)

        {:ok,
         %DDD.Page{
           entries: entries,
           page: number,
           page_size: size,
           total_entries: total,
           total_pages: div(total + size - 1, size)
         }}
      end
    end)
  end

  @spec slice(ctx(), keyword()) :: {:ok, DDD.Slice.t()} | {:error, DDD.Error.t()}
  def slice(ctx, opts) do
    guarded(fn ->
      with {:ok, query} <- filtered(ctx, opts),
           {:ok, order} <- normalize_order(ctx, opts[:order]),
           {:ok, size} <- size_option(opts[:limit], @default_page_size),
           {:ok, query} <- after_cursor(query, order, opts[:after]) do
        # One extra row tells us whether there is a next slice.
        rows = query |> order_by(^order) |> limit(^(size + 1)) |> ctx.repo.all()
        {window, rest} = Enum.split(rows, size)

        next =
          if rest != [], do: encode_cursor(order, cursor_values(order, List.last(window)))

        {:ok, %DDD.Slice{entries: Enum.map(window, ctx.map), next_cursor: next, limit: size}}
      end
    end)
  end

  # A value of the wrong type for its column ("not-a-uuid" for a uuid) is the caller's bad input.
  defp guarded(fun) do
    fun.()
  rescue
    exception in [Ecto.Query.CastError, Ecto.QueryError, Ecto.ChangeError] ->
      {:error,
       error(:invalid_filter, "a value does not fit its field: #{Exception.message(exception)}")}
  end

  defp error(code, message, details \\ %{}),
    do: DDD.Error.business(operation: :list, code: code, message: message, details: details)

  # ── Filtering ────────────────────────────────────────────────────────────

  defp filtered(ctx, opts) do
    filters =
      Enum.reject([opts[:filter], opts[:spec] && {:spec, opts[:spec]}], &is_nil/1)

    with {:ok, where} <- DDD.Filter.build(filters, ctx.types) do
      {:ok, from(r in ctx.schema, where: ^where)}
    end
  end

  # ── Ordering ─────────────────────────────────────────────────────────────

  defp normalize_order(ctx, order) do
    sortable = Map.keys(ctx.types) ++ [ctx.pk]

    entries =
      order
      |> List.wrap()
      |> Enum.map(fn
        {dir, field} when dir in [:asc, :desc] and is_atom(field) -> {dir, field}
        field when is_atom(field) and not is_nil(field) -> {:asc, field}
        other -> {:invalid, other}
      end)

    cond do
      bad = Enum.find(entries, &match?({:invalid, _}, &1)) ->
        {:error,
         error(:invalid_order, "not a sort order: #{inspect(elem(bad, 1))}", %{
           order: inspect(order)
         })}

      bad = Enum.find(entries, fn {_dir, field} -> field not in sortable end) ->
        {:error,
         error(:invalid_order, "cannot sort by #{inspect(elem(bad, 1))}", %{
           field: elem(bad, 1),
           fields: Enum.sort(sortable)
         })}

      true ->
        tie_breaker =
          if Enum.any?(entries, fn {_d, field} -> field == ctx.pk end),
            do: [],
            else: [asc: ctx.pk]

        {:ok, entries ++ tie_breaker}
    end
  end

  defp size_option(nil, nil), do: {:ok, nil}
  defp size_option(value, default), do: positive(value, default, :limit, @max_page_size)

  defp positive(value, default, name, max \\ nil)
  defp positive(nil, default, _name, _max), do: {:ok, default}

  defp positive(value, _default, _name, max) when is_integer(value) and value >= 1,
    do: {:ok, if(max, do: min(value, max), else: value)}

  defp positive(value, _default, name, _max),
    do:
      {:error, error(:invalid_page, "#{name} must be a positive integer, got #{inspect(value)}")}

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  # ── Cursors (keyset pagination) ──────────────────────────────────────────

  defp cursor_values(order, record),
    do: Enum.map(order, fn {_dir, field} -> Map.fetch!(record, field) end)

  defp encode_cursor(order, values),
    do: {order, values} |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  defp decode_cursor(cursor) do
    with {:ok, binary} <- Base.url_decode64(cursor, padding: false),
         {order, values} when is_list(order) and is_list(values) <-
           :erlang.binary_to_term(binary, [:safe]) do
      {:ok, order, values}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp after_cursor(query, _order, nil), do: {:ok, query}

  defp after_cursor(query, order, cursor) when is_binary(cursor) do
    case decode_cursor(cursor) do
      {:ok, ^order, values} when length(values) == length(order) ->
        {:ok, where(query, ^keyset(order, values))}

      _ ->
        {:error, error(:invalid_cursor, "the cursor is not valid for this listing and order")}
    end
  end

  defp after_cursor(_query, _order, _other),
    do: {:error, error(:invalid_cursor, "the cursor is not valid for this listing and order")}

  # "After the row with these values": for ORDER BY a, b, c the rows where
  #   a > va  OR  (a = va AND b > vb)  OR  (a = va AND b = vb AND c > vc)
  # (`<` for a descending field).
  defp keyset(order, values) do
    pairs = Enum.zip(order, values)

    pairs
    |> Enum.with_index()
    |> Enum.map(fn {{{dir, field}, value}, index} ->
      equal =
        pairs
        |> Enum.take(index)
        |> Enum.reduce(dynamic([r], true), fn {{_d, f}, v}, acc ->
          dynamic([r], ^acc and field(r, ^f) == ^v)
        end)

      case dir do
        :asc -> dynamic([r], ^equal and field(r, ^field) > ^value)
        :desc -> dynamic([r], ^equal and field(r, ^field) < ^value)
      end
    end)
    |> Enum.reduce(fn next, acc -> dynamic([r], ^acc or ^next) end)
  end
end
