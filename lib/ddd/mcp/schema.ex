defmodule DDD.MCP.Schema do
  @moduledoc """
  JSON Schema for the input of a command or query, built from its declared fields.

  The type of each field becomes the schema of the parameter, `description:` its description,
  `required: true` puts it in `required`, and a `default:` is advertised. This is what an AI
  client reads to know how to call the tool.
  """

  # Nested entities are described to this depth; deeper levels are left as plain objects.
  @max_depth 4

  @doc "The JSON Schema (`type: object`) for the parameters of a command or query module."
  @spec input(module()) :: map()
  def input(module) do
    params = module.__params__()

    properties =
      for {name, type, opts} <- params, into: %{} do
        {Atom.to_string(name), property(type, opts)}
      end

    required = for {name, _type, opts} <- params, opts[:required], do: Atom.to_string(name)

    %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    |> put_unless_empty("required", required)
  end

  defp property(type, opts) do
    type
    |> type(@max_depth)
    |> put_present("description", opts[:description])
    |> put_present("default", default(type, opts[:default]))
  end

  defp default(_type, nil), do: nil
  defp default(type, value), do: DDD.Type.json_dump(type, value)

  @doc "The JSON Schema of a `DDD.Type`."
  @spec type(DDD.Type.t(), non_neg_integer()) :: map()
  def type(type, depth \\ @max_depth)

  def type(type, _depth) when type in [:string, :text, :atom], do: %{"type" => "string"}
  def type(:integer, _depth), do: %{"type" => "integer"}
  def type(:float, _depth), do: %{"type" => "number"}
  def type(:boolean, _depth), do: %{"type" => "boolean"}
  def type(:uuid, _depth), do: %{"type" => "string", "format" => "uuid"}
  def type(:decimal, _depth), do: %{"type" => ["string", "number"], "description" => "A decimal"}
  def type(:date, _depth), do: %{"type" => "string", "format" => "date"}
  def type(:time, _depth), do: %{"type" => "string", "format" => "time"}

  def type(type, _depth) when type in [:naive_datetime, :datetime, :datetime_usec],
    do: %{"type" => "string", "format" => "date-time"}

  def type(:binary, _depth), do: %{"type" => "string", "contentEncoding" => "base64"}
  def type(:map, _depth), do: %{"type" => "object"}
  def type(:json, _depth), do: %{}
  def type(:list, _depth), do: %{"type" => "array"}

  def type({:enum, values}, _depth),
    do: %{"type" => "string", "enum" => Enum.map(values, &to_string/1)}

  def type({:array, inner}, depth), do: %{"type" => "array", "items" => type(inner, depth)}

  def type({:map, inner}, depth),
    do: %{"type" => "object", "additionalProperties" => type(inner, depth)}

  def type({:ref, module}, depth), do: module |> DDD.Type.identity_type() |> type(depth)
  def type({:one, module}, depth), do: nested(module, depth)
  def type({:list, module}, depth), do: %{"type" => "array", "items" => nested(module, depth)}

  defp nested(_module, depth) when depth <= 0, do: %{"type" => "object"}

  defp nested(module, depth) do
    fields = module.__ddd_fields__()

    properties =
      for {name, type, opts} <- fields, into: %{} do
        {Atom.to_string(name),
         type |> type(depth - 1) |> put_present("description", opts[:description])}
      end

    %{"type" => "object", "properties" => properties}
    |> put_present("description", module.__ddd_description__())
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)
end
