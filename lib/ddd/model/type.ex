defmodule DDD.Type do
  @moduledoc """
  The field types of entities, aggregates and value objects, and everything the framework
  does with them: checking a value, storing it in Postgres, and writing it as JSON.

  ## Scalars

  | type                | Elixir value        | Postgres column            |
  |---------------------|---------------------|----------------------------|
  | `:string`           | binary              | `varchar`                  |
  | `:text`             | binary              | `text`                     |
  | `:integer`          | integer             | `bigint`                   |
  | `:float`            | number              | `float`                    |
  | `:boolean`          | boolean             | `boolean`                  |
  | `:atom`             | atom                | `varchar` (as a string)    |
  | `:uuid`             | UUID string         | `uuid`                     |
  | `:decimal`          | `Decimal`           | `numeric`                  |
  | `:date`             | `Date`              | `date`                     |
  | `:time`             | `Time`              | `time(6)`                  |
  | `:naive_datetime`   | `NaiveDateTime`     | `timestamp(6)`             |
  | `:datetime`         | `DateTime`          | `timestamp(0)`             |
  | `:datetime_usec`    | `DateTime`          | `timestamp(6)`             |
  | `:binary`           | binary              | `bytea`                    |
  | `:map`              | map                 | `jsonb`                    |
  | `:json`             | map or list         | `jsonb`                    |

  ## Composite types

    * `{:array, type}`: a list of `type` (a scalar, enum, reference, value object or map),
      stored as a Postgres array, for example `{:array, :string}` for tags
    * `{:enum, [:open, :done]}`: one of the listed atoms, stored as a string
    * `{:map, type}`: a map with string keys and values of `type`, stored as `jsonb`
    * `{:ref, Aggregate}`: the identity of another aggregate. The aggregates refer to each other
      by id only. It has the type of that aggregate's identity
    * `{:one, Module}` / `{:list, Module}`: nested entities or value objects, stored as `jsonb`
    * `:money`: shorthand for `{:one, DDD.Money}`

  A value that does not fit its type is a validation violation with the code `:invalid_type`.
  `nil` is always accepted by the type (use `required: true` to forbid it).
  """

  @scalars ~w(string text integer float boolean atom uuid decimal date time naive_datetime
              datetime datetime_usec binary map json list)a

  @type t ::
          atom()
          | {:array, t()}
          | {:enum, [atom()]}
          | {:map, t()}
          | {:ref, module()}
          | {:one, module()}
          | {:list, module()}

  # ── Declaration ───────────────────────────────────────────────────────────

  @doc """
  Check a declared type and expand its shorthands. Raises `ArgumentError` on an unknown type,
  so a typo fails at compile time.

      iex> DDD.Type.normalize!(:money)
      {:one, DDD.Money}
      iex> DDD.Type.normalize!({:array, :string})
      {:array, :string}
  """
  @spec normalize!(term()) :: t()
  def normalize!(:money), do: {:one, DDD.Money}
  def normalize!(type) when type in @scalars, do: type

  def normalize!({:array, inner}) do
    case normalize!(inner) do
      {:array, _} -> raise ArgumentError, "arrays of arrays are not supported: #{inspect(inner)}"
      inner -> {:array, inner}
    end
  end

  def normalize!({:map, inner}), do: {:map, normalize!(inner)}

  def normalize!({:enum, [_ | _] = values} = type) do
    if Enum.all?(values, &(is_atom(&1) and not is_nil(&1) and not is_boolean(&1))),
      do: type,
      else: raise(ArgumentError, "enum values must be atoms: #{inspect(values)}")
  end

  def normalize!({kind, module} = type) when kind in [:ref, :one, :list] and is_atom(module),
    do: type

  def normalize!(other), do: raise(ArgumentError, "unknown field type: #{inspect(other)}")

  # ── Checking values ───────────────────────────────────────────────────────

  @doc """
  True when `value` fits `type` (`nil` always does).

      iex> DDD.Type.valid?({:enum, [:open, :done]}, :open)
      true
      iex> DDD.Type.valid?({:enum, [:open, :done]}, :weird)
      false
      iex> DDD.Type.valid?({:array, :integer}, [1, 2])
      true
      iex> DDD.Type.valid?(:integer, nil)
      true
  """
  @spec valid?(t(), term()) :: boolean()
  def valid?(_type, nil), do: true
  def valid?(type, value) when type in [:string, :text, :binary], do: is_binary(value)
  def valid?(:integer, value), do: is_integer(value)
  def valid?(:float, value), do: is_number(value)
  def valid?(:boolean, value), do: is_boolean(value)
  def valid?(:atom, value), do: is_atom(value)
  def valid?(:uuid, value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))
  def valid?(:decimal, value), do: is_struct(value, Decimal)
  def valid?(:date, value), do: is_struct(value, Date)
  def valid?(:time, value), do: is_struct(value, Time)
  def valid?(:naive_datetime, value), do: is_struct(value, NaiveDateTime)
  def valid?(type, value) when type in [:datetime, :datetime_usec], do: is_struct(value, DateTime)
  def valid?(:map, value), do: is_map(value) and not is_struct(value)
  def valid?(:json, value), do: (is_map(value) and not is_struct(value)) or is_list(value)
  def valid?(:list, value), do: is_list(value)
  def valid?({:array, inner}, value), do: is_list(value) and Enum.all?(value, &valid?(inner, &1))
  def valid?({:enum, values}, value), do: value in values
  def valid?({:ref, module}, value), do: valid?(identity_type(module), value)
  def valid?({:one, module}, value), do: is_struct(value, module)

  def valid?({:list, module}, value),
    do: is_list(value) and Enum.all?(value, &is_struct(&1, module))

  def valid?({:map, inner}, value) do
    is_map(value) and not is_struct(value) and
      Enum.all?(value, fn {key, v} -> (is_binary(key) or is_atom(key)) and valid?(inner, v) end)
  end

  def valid?(_type, _value), do: false

  @doc "A short description of a type, for error messages."
  @spec describe(t()) :: String.t()
  def describe({:enum, values}), do: "one of #{inspect(values)}"
  def describe({:ref, module}), do: "the id of a #{inspect(module)}"
  def describe({:one, module}), do: "a #{inspect(module)}"
  def describe({:list, module}), do: "a list of #{inspect(module)}"
  def describe({:array, inner}), do: "a list of #{describe(inner)}"
  def describe({:map, inner}), do: "a map of #{describe(inner)}"
  def describe(type), do: "a #{type}"

  @doc "The type of an aggregate's identity (what `{:ref, Aggregate}` holds)."
  @spec identity_type(module()) :: t()
  def identity_type(module) do
    {:module, _} = Code.ensure_compiled(module)

    case module.__ddd_identity__() do
      [{_name, type, _opts}] -> type
      # A composite identity is referenced by its identity string.
      [_, _ | _] -> :string
      [] -> raise ArgumentError, "#{inspect(module)} has no identity, so it can't be referenced"
    end
  end

  # ── Postgres ──────────────────────────────────────────────────────────────

  @doc "The Ecto type the adapter uses for a field."
  @spec ecto_type(t()) :: Ecto.Type.t()
  def ecto_type(type) when type in [:string, :text, :atom], do: :string

  def ecto_type(type) when type in [:integer, :float, :boolean, :decimal, :date, :binary],
    do: type

  def ecto_type(:uuid), do: :binary_id
  def ecto_type(:time), do: :time_usec
  def ecto_type(:naive_datetime), do: :naive_datetime_usec
  def ecto_type(:datetime), do: :utc_datetime
  def ecto_type(:datetime_usec), do: :utc_datetime_usec
  def ecto_type(:map), do: :map
  def ecto_type(:json), do: DDD.Type.Json
  def ecto_type(:list), do: DDD.Type.Json
  def ecto_type({:enum, _}), do: :string
  def ecto_type({:ref, module}), do: module |> identity_type() |> ecto_type()
  def ecto_type({:one, _}), do: :map
  def ecto_type({:map, _}), do: :map
  # Nested entities, maps and lists of them are one JSON column, never a Postgres array of
  # JSON (`jsonb[]`): one value to read and write, and nothing that ties it to Postgres.
  def ecto_type({:list, _}), do: DDD.Type.Json
  def ecto_type({:array, inner}) when inner in [:map, :json, :list], do: DDD.Type.Json

  def ecto_type({:array, inner}),
    do: if(composite?(inner), do: DDD.Type.Json, else: {:array, ecto_type(inner)})

  @doc "The column type a migration uses for a field (what the snapshot records)."
  @spec column_type(t()) :: Ecto.Type.t()
  def column_type(:text), do: :text
  def column_type({:array, :text}), do: {:array, :text}
  def column_type(type), do: type |> ecto_type() |> json_column()

  defp json_column(DDD.Type.Json), do: :map
  defp json_column(type), do: type

  # A column holds scalars natively; nested structs and maps are stored as JSON.
  defp composite?({kind, _}) when kind in [:one, :list, :map], do: true
  defp composite?({:array, inner}), do: composite?(inner)
  defp composite?(_), do: false

  @doc "A field value as the value of its Ecto column."
  @spec dump(t(), term()) :: term()
  def dump(_type, nil), do: nil
  def dump({:ref, module}, value), do: module |> identity_type() |> dump(value)

  def dump(type, value) do
    if composite?(type), do: json_dump(type, value), else: dump_native(type, value)
  end

  defp dump_native(:atom, value) when is_atom(value), do: Atom.to_string(value)
  defp dump_native({:enum, _}, value) when is_atom(value), do: Atom.to_string(value)
  defp dump_native(:float, value) when is_integer(value), do: value * 1.0
  defp dump_native({:array, inner}, list) when is_list(list), do: Enum.map(list, &dump(inner, &1))
  defp dump_native(_type, value), do: value

  @doc "A field value read from its Ecto column."
  @spec load(t(), term()) :: term()
  def load(_type, nil), do: nil
  def load({:ref, module}, value), do: module |> identity_type() |> load(value)

  def load(type, value) do
    if composite?(type), do: json_load(type, value), else: load_native(type, value)
  end

  # Stored values were written by this application, so reading one may create its atom: with
  # `String.to_existing_atom/1` a row would be unreadable on a node that has not yet loaded the
  # module that mentions it. Input from a client never gets here (see `DDD.MCP.Args`). An
  # `{:enum, [...]}` field is the safer choice, as it can only hold the listed atoms.
  defp load_native(:atom, value) when is_binary(value), do: String.to_atom(value)
  defp load_native({:enum, values}, value), do: to_enum(values, value)
  defp load_native({:array, inner}, list) when is_list(list), do: Enum.map(list, &load(inner, &1))
  defp load_native(_type, value), do: value

  # ── JSON (nested entities, maps, `jsonb`) ─────────────────────────────────

  @doc "A value as JSON-ready data (strings, numbers, booleans, lists, maps)."
  @spec json_dump(t(), term()) :: term()
  def json_dump(_type, nil), do: nil
  def json_dump(:atom, value) when is_atom(value), do: Atom.to_string(value)
  def json_dump({:enum, _}, value) when is_atom(value), do: Atom.to_string(value)
  def json_dump(:decimal, %Decimal{} = value), do: Decimal.to_string(value)
  def json_dump(:date, %Date{} = value), do: Date.to_iso8601(value)
  def json_dump(:time, %Time{} = value), do: Time.to_iso8601(value)
  def json_dump(:naive_datetime, %NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  def json_dump(type, %DateTime{} = value) when type in [:datetime, :datetime_usec],
    do: DateTime.to_iso8601(value)

  def json_dump(:binary, value) when is_binary(value), do: Base.encode64(value)
  def json_dump({:ref, module}, value), do: module |> identity_type() |> json_dump(value)
  def json_dump({:one, _}, value), do: DDD.Serializer.dump(value)
  def json_dump({:list, _}, list), do: Enum.map(list, &DDD.Serializer.dump/1)
  def json_dump({:array, inner}, list), do: Enum.map(list, &json_dump(inner, &1))

  def json_dump({:map, inner}, map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_dump(inner, value)} end)

  def json_dump(_type, value), do: value

  @doc "The inverse of `json_dump/2`."
  @spec json_load(t(), term()) :: term()
  def json_load(_type, nil), do: nil
  def json_load(:atom, value) when is_binary(value), do: String.to_atom(value)
  def json_load({:enum, values}, value), do: to_enum(values, value)
  def json_load(:decimal, value) when is_binary(value), do: Decimal.new(value)
  def json_load(:decimal, value) when is_integer(value), do: Decimal.new(value)
  def json_load(:decimal, value) when is_float(value), do: Decimal.from_float(value)
  def json_load(:date, value) when is_binary(value), do: Date.from_iso8601!(value)
  def json_load(:time, value) when is_binary(value), do: Time.from_iso8601!(value)

  def json_load(:naive_datetime, value) when is_binary(value),
    do: NaiveDateTime.from_iso8601!(value)

  def json_load(type, value) when type in [:datetime, :datetime_usec] and is_binary(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  def json_load(:binary, value) when is_binary(value), do: Base.decode64!(value)
  def json_load({:ref, module}, value), do: module |> identity_type() |> json_load(value)
  def json_load({:one, module}, map) when is_map(map), do: DDD.Serializer.load(module, map)

  def json_load({:list, module}, list) when is_list(list),
    do: Enum.map(list, &DDD.Serializer.load(module, &1))

  def json_load({:array, inner}, list) when is_list(list),
    do: Enum.map(list, &json_load(inner, &1))

  def json_load({:map, inner}, map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, json_load(inner, value)} end)

  def json_load(_type, value), do: value

  # An enum value that is no longer listed (the list shrank since the row was written) is
  # returned as stored, so reading never crashes. It then fails `valid?/2` on the next change.
  defp to_enum(_values, value) when is_atom(value), do: value

  defp to_enum(values, value) when is_binary(value) do
    Enum.find(values, value, &(Atom.to_string(&1) == value))
  end
end
