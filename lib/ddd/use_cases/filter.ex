defmodule DDD.Filter do
  @moduledoc """
  A small, safe filter language that becomes a SQL `WHERE`, for the listing functions of
  `DDD.Repository.Ecto` adapters and `DDD.Projection`s (`list/1`, `page/1`, `slice/1`,
  `count/1`).

      [owner_id: id, status: :open]                       # all of them (AND)
      [open_count: {:gt, 3}]                              # a comparison
      {:or, [[status: :open], [title: {:like, "Buy%"}]]}
      {:not, [status: :done]}
      [{:spec, MyApp.Specs.Overdue}]                      # a specification, see below

  Forms (`field` is an atom, `value` is in its domain form: atoms, `Date`s, ids as strings):

  | form | meaning |
  |---|---|
  | `{field, value}` | equal (`nil` means `IS NULL`) |
  | `{field, {op, value}}` or `{field, op, value}` | `op` is `:eq`, `:neq`, `:gt`, `:gte`, `:lt`, `:lte`, `:in`, `:not_in`, `:like`, `:ilike` |
  | `[filter, ...]` or a keyword list or a map | every one of them |
  | `{:and, [filter]}`, `{:or, [filter]}`, `{:not, filter}` | combinators (so `:and`, `:or`, `:not` can't be field names here) |
  | `{:spec, spec}` | a `DDD.Specification` translated by `DDD.Specification.to_filter/2` |

  Values are never interpolated into SQL: they are bound parameters, converted with
  `DDD.Type.dump/2` the same way `find_by_*` does. An unknown field, an unknown operator or a
  malformed expression is a business error with code `:invalid_filter` (so a filter built from a
  client's request can be answered with it), never a crash or an injection.
  """

  import Ecto.Query, only: [dynamic: 2]

  @ops [:eq, :neq, :gt, :gte, :lt, :lte, :in, :not_in, :like, :ilike]

  @doc """
  Build the `Ecto.Query.dynamic/2` for `filter`. `types` maps each field to its domain type
  (`%{title: :string, ...}`); only those fields can be filtered on.
  """
  @spec build(term(), %{atom() => term()}) ::
          {:ok, Ecto.Query.dynamic_expr()} | {:error, DDD.Error.t()}
  def build(filter, types) do
    {:ok, to_dynamic(filter, types)}
  catch
    {:invalid_filter, message, details} ->
      {:error,
       DDD.Error.business(
         operation: :filter,
         code: :invalid_filter,
         message: message,
         details: details
       )}
  end

  defp to_dynamic([], _types), do: dynamic([r], true)

  defp to_dynamic(list, types) when is_list(list),
    do: list |> Enum.map(&to_dynamic(&1, types)) |> all()

  defp to_dynamic(map, types) when is_map(map) and not is_struct(map),
    do: map |> Map.to_list() |> to_dynamic(types)

  defp to_dynamic({:and, filters}, types) when is_list(filters),
    do: filters |> Enum.map(&to_dynamic(&1, types)) |> all()

  defp to_dynamic({:or, filters}, types) when is_list(filters),
    do: filters |> Enum.map(&to_dynamic(&1, types)) |> any()

  defp to_dynamic({:not, filter}, types) do
    inner = to_dynamic(filter, types)
    dynamic([r], not (^inner))
  end

  defp to_dynamic({:spec, spec}, types),
    do: spec |> DDD.Specification.to_filter() |> to_dynamic(types)

  defp to_dynamic({field, op, value}, types) when is_atom(field) and is_atom(op),
    do: compare(field, op, value, types)

  defp to_dynamic({field, {op, value}}, types) when is_atom(field) and op in @ops,
    do: compare(field, op, value, types)

  defp to_dynamic({field, value}, types) when is_atom(field),
    do: compare(field, :eq, value, types)

  defp to_dynamic(other, _types),
    do: throw({:invalid_filter, "not a filter: #{inspect(other)}", %{filter: inspect(other)}})

  defp all(dynamics),
    do:
      Enum.reduce(dynamics, dynamic([r], true), fn next, acc -> dynamic([r], ^acc and ^next) end)

  defp any([]), do: dynamic([r], false)

  defp any([first | rest]),
    do: Enum.reduce(rest, first, fn next, acc -> dynamic([r], ^acc or ^next) end)

  defp compare(field, op, value, types) do
    type =
      case Map.fetch(types, field) do
        {:ok, type} ->
          type

        :error ->
          throw(
            {:invalid_filter, "unknown field #{inspect(field)}",
             %{field: field, fields: types |> Map.keys() |> Enum.sort()}}
          )
      end

    if op not in @ops,
      do:
        throw({:invalid_filter, "unknown operator #{inspect(op)}", %{field: field, operator: op}})

    build_compare(field, op, value, type)
  end

  defp build_compare(field, :eq, nil, _type), do: dynamic([r], is_nil(field(r, ^field)))
  defp build_compare(field, :neq, nil, _type), do: dynamic([r], not is_nil(field(r, ^field)))

  defp build_compare(field, :eq, value, type),
    do:
      (
        v = dump(type, value)
        dynamic([r], field(r, ^field) == ^v)
      )

  defp build_compare(field, :neq, value, type),
    do:
      (
        v = dump(type, value)
        dynamic([r], field(r, ^field) != ^v)
      )

  defp build_compare(field, :gt, value, type),
    do:
      (
        v = dump(type, value)
        dynamic([r], field(r, ^field) > ^v)
      )

  defp build_compare(field, :gte, value, type),
    do:
      (
        v = dump(type, value)
        dynamic([r], field(r, ^field) >= ^v)
      )

  defp build_compare(field, :lt, value, type),
    do:
      (
        v = dump(type, value)
        dynamic([r], field(r, ^field) < ^v)
      )

  defp build_compare(field, :lte, value, type),
    do:
      (
        v = dump(type, value)
        dynamic([r], field(r, ^field) <= ^v)
      )

  defp build_compare(field, :in, values, type) when is_list(values) do
    vs = Enum.map(values, &dump(type, &1))
    dynamic([r], field(r, ^field) in ^vs)
  end

  defp build_compare(field, :not_in, values, type) when is_list(values) do
    vs = Enum.map(values, &dump(type, &1))
    dynamic([r], field(r, ^field) not in ^vs)
  end

  defp build_compare(field, :like, pattern, _type) when is_binary(pattern),
    do: dynamic([r], like(field(r, ^field), ^pattern))

  defp build_compare(field, :ilike, pattern, _type) when is_binary(pattern),
    do: dynamic([r], ilike(field(r, ^field), ^pattern))

  defp build_compare(field, op, value, _type),
    do:
      throw(
        {:invalid_filter, "#{inspect(op)} on #{inspect(field)} does not accept #{inspect(value)}",
         %{field: field, operator: op}}
      )

  defp dump(type, value), do: DDD.Type.dump(type, value)
end
