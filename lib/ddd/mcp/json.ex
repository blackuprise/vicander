defmodule DDD.MCP.Json do
  @moduledoc """
  Turns the result of a command, query or repository lookup into JSON.

  Domain structs (aggregates, entities, value objects) are written with `DDD.Serializer`, so
  every field type has its JSON form (decimals and dates as text, enums as strings, nested
  entities as objects). Everything else is converted structurally. All fields are shown: a
  query that must hide something returns a map it built itself.
  """

  @doc "A JSON-ready term (maps with string keys, lists, strings, numbers, booleans, nil)."
  @spec prepare(term()) :: term()
  def prepare(nil), do: nil
  def prepare(value) when is_boolean(value) or is_number(value) or is_binary(value), do: value
  def prepare(value) when is_atom(value), do: Atom.to_string(value)
  def prepare(%Decimal{} = value), do: Decimal.to_string(value)
  def prepare(%Date{} = value), do: Date.to_iso8601(value)
  def prepare(%Time{} = value), do: Time.to_iso8601(value)
  def prepare(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def prepare(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def prepare(%{__struct__: module, __sealed__: _} = struct) do
    if function_exported?(module, :__ddd_fields__, 0),
      do: DDD.Serializer.dump(struct),
      else: struct |> Map.from_struct() |> Map.delete(:__sealed__) |> prepare()
  end

  def prepare(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> prepare()
  def prepare(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), prepare(v)} end)
  def prepare(list) when is_list(list), do: Enum.map(list, &prepare/1)
  def prepare(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> prepare()
  def prepare(other), do: inspect(other)

  @doc "The JSON text of `value`."
  @spec encode(term()) :: String.t()
  def encode(value), do: value |> prepare() |> Jason.encode!()

  defp key(key) when is_binary(key), do: key
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: inspect(key)
end
