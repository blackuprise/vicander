defmodule DDD.MCP.Args do
  @moduledoc """
  Turns the JSON arguments of a tool call into the typed attributes of a command or query.

  Strings become dates, decimals, enum atoms and so on through `DDD.Type`. Nested entities and
  value objects are built with their own `new/1`, so their rules run: a client can never hand
  the application a nested struct that skipped validation. Atoms are never created from input.
  """

  alias DDD.Error

  @doc """
  Cast the string-keyed `args` for the parameters of `module` (a command or query).

  Returns `{:ok, attrs}` or `{:error, %DDD.Error{}}` listing every argument that could not be
  converted. A `null` argument counts as absent.
  """
  @spec cast(module(), map()) :: {:ok, map()} | {:error, Error.t()}
  def cast(module, args) do
    {attrs, violations} =
      Enum.reduce(module.__params__(), {%{}, []}, fn {name, type, _opts}, {attrs, violations} ->
        case Map.get(args, Atom.to_string(name)) do
          nil -> {attrs, violations}
          value -> put_cast(attrs, violations, name, type, value)
        end
      end)

    case violations do
      [] -> {:ok, attrs}
      _ -> {:error, Error.validation_failed(module, :new, Enum.reverse(violations))}
    end
  end

  defp put_cast(attrs, violations, name, type, value) do
    case cast_value(type, value) do
      {:ok, cast} ->
        {Map.put(attrs, name, cast), violations}

      :error ->
        violation = Error.violation(name, :invalid_type, "must be #{DDD.Type.describe(type)}")
        {attrs, [violation | violations]}

      {:error, %Error{} = error} ->
        violation =
          Error.violation(name, :invalid, "is invalid", %{errors: Error.to_map(error)})

        {attrs, [violation | violations]}
    end
  end

  @doc """
  Cast one value of a URI (always a string) to the field type: `"5"` for an integer field,
  `"2030-01-02"` for a date.
  """
  @spec from_string(DDD.Type.t(), String.t()) :: {:ok, term()} | :error
  def from_string(:integer, string) do
    case Integer.parse(string) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  def from_string(:float, string) do
    case Float.parse(string) do
      {float, ""} -> {:ok, float}
      _ -> :error
    end
  end

  def from_string(:boolean, "true"), do: {:ok, true}
  def from_string(:boolean, "false"), do: {:ok, false}
  def from_string(:boolean, _), do: :error
  def from_string({:ref, module}, string), do: from_string(DDD.Type.identity_type(module), string)

  def from_string(type, string) do
    case cast_value(type, string) do
      {:ok, _} = ok -> ok
      _ -> :error
    end
  end

  # ── One value ─────────────────────────────────────────────────────────────

  defp cast_value({:one, module}, map) when is_map(map), do: build(module, map)

  defp cast_value({:list, module}, list) when is_list(list),
    do: cast_each(list, &build(module, &1))

  defp cast_value({:array, inner}, list) when is_list(list),
    do: cast_each(list, &cast_value(inner, &1))

  defp cast_value({:map, inner}, map) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case cast_value(inner, value) do
        {:ok, cast} -> {:cont, {:ok, Map.put(acc, key, cast)}}
        other -> {:halt, other}
      end
    end)
  end

  defp cast_value({:ref, module}, value), do: cast_value(DDD.Type.identity_type(module), value)

  # Input from a client never creates an atom: only one that already exists is accepted.
  defp cast_value(:atom, value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  defp cast_value(type, value) do
    loaded = DDD.Type.json_load(type, value)
    if DDD.Type.valid?(type, loaded), do: {:ok, loaded}, else: :error
  rescue
    # A bad date, an atom that does not exist, invalid base64...
    _ -> :error
  end

  defp cast_each(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case fun.(element) do
        {:ok, cast} -> {:cont, {:ok, [cast | acc]}}
        other -> {:halt, other}
      end
    end)
    |> case do
      {:ok, cast} -> {:ok, Enum.reverse(cast)}
      other -> other
    end
  end

  # A nested entity or value object is built by its own `new/1`, so its rules run.
  defp build(module, map) when is_map(map) do
    # `{:ok, value} <- [Map.fetch(...)]`, not `value = Map.get(...)`: a bare match in a
    # comprehension is a filter, and `false` would be filtered out like `nil`.
    attrs =
      for {name, type, _opts} <- module.__ddd_fields__(),
          {:ok, value} <- [Map.fetch(map, Atom.to_string(name))],
          not is_nil(value),
          into: %{} do
        case cast_value(type, value) do
          {:ok, cast} -> {name, cast}
          # Left as given: `new/1` reports the wrong type under the field's name.
          _ -> {name, value}
        end
      end

    module.new(attrs)
  end

  defp build(_module, _other), do: :error
end
