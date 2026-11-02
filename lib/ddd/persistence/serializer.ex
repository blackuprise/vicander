defmodule DDD.Serializer do
  @moduledoc """
  Converts nested entities to JSON-ready maps and back.

  Used by `DDD.Type` to store `{:list, Entity}`, `{:one, ValueObject}` and the other nested
  field types in a `jsonb` column. `load/2` fills defaults for keys missing from old rows and
  seals the rebuilt struct (the data is trusted, it came from the store).
  """

  @doc "Dump a value of the given field type to a JSON-ready term."
  @spec dump_value(term(), term()) :: term()
  defdelegate dump_value(type, value), to: DDD.Type, as: :json_dump

  @doc "Load a value of the given field type from its dumped form."
  @spec load_value(term(), term()) :: term()
  defdelegate load_value(type, value), to: DDD.Type, as: :json_load

  @doc "Dump a struct to a map with string keys."
  @spec dump(struct()) :: map()
  def dump(%{__struct__: module} = struct) do
    for {name, type, _opts} <- module.__ddd_fields__(), into: %{} do
      {Atom.to_string(name), DDD.Type.json_dump(type, Map.get(struct, name))}
    end
  end

  @doc "Rebuild a sealed struct of `module` from a dumped map (string or atom keys)."
  @spec load(module(), map()) :: struct()
  def load(module, map) do
    attrs =
      for {name, type, opts} <- module.__ddd_fields__(), into: %{} do
        value =
          case fetch(map, name) do
            {:ok, value} -> DDD.Type.json_load(type, value)
            :error -> Keyword.get(opts, :default)
          end

        {name, value}
      end

    module |> struct(attrs) |> DDD.Schema.seal()
  end

  defp fetch(map, name) do
    case Map.fetch(map, Atom.to_string(name)) do
      {:ok, _} = found -> found
      :error -> Map.fetch(map, name)
    end
  end
end
