defmodule DDD.Identity do
  @moduledoc """
  Identities of entities and aggregates, and generating them.

  ## The identity string

  An entity's identity is made of one or more fields, declared with one `identity/2` each:

      identity(:tenant_id, :uuid)
      identity(:sku, :string)

  `Entity.identity(entity)` returns it as a string: the value itself for a single field, the
  values joined with `:` for several (`"6f1f...:A-100"`). A `\\` or `:` inside a part is escaped
  (`\\\\`, `\\:`) so the string always splits back into the same parts (`decode/1`). The string
  is what `find_by_id/1`, the outbox `aggregate_id` and a `{:ref, Aggregate}` to a composite
  aggregate use.

  `Entity.build_identity(parts)` makes the same string from a map or keyword list of the parts,
  without an entity. `Entity.identity_fields()` lists the part names.

  A composite identity part must be a `:string`, `:uuid`, `:integer`, `:atom`, `:date` or
  enum field. Every part is required, and none may change once the entity exists.

  ## Generating ids

  `new/1` fills in a UUIDv7 only for a single `identity(:id, :uuid)` that the caller left out.
  For any other identity the caller passes every part. `generate/0` and the functions below
  make ids by hand:

    * `uuid7/0` (the default, `generate/0`) - time-ordered: ids created later sort later, which
      keeps btree indexes compact
    * `uuid4/0` - random
    * `uuid1/0`, `uuid3/2`, `uuid5/2` - time and name based (see `UUID`)
  """

  @composite_types [:string, :uuid, :integer, :atom, :date]

  @doc "A new id: a UUIDv7."
  @spec generate() :: String.t()
  def generate, do: uuid7()

  @doc """
  Fills in a generated `:id` when the identity is a lone `identity(:id, :uuid)` and the caller
  left it out. Any other identity is returned untouched. A function rather than inline code in
  the generated `new/1`, so a value object (no identity) does not get a clause that can never
  match.
  """
  @spec put_generated(map(), [{atom(), atom(), keyword()}]) :: map()
  def put_generated(attrs, [{:id, :uuid, _opts}]), do: Map.put_new_lazy(attrs, :id, &generate/0)
  def put_generated(attrs, _identity), do: attrs

  @doc """
  A UUIDv7: a 48-bit millisecond timestamp followed by random bits.

  Ids made in different milliseconds sort in creation order. Ids made within the same
  millisecond are unique but not ordered.
  """
  @spec uuid7() :: String.t()
  def uuid7 do
    <<rand_a::12, rand_b::62, _unused::6>> = :crypto.strong_rand_bytes(10)
    millis = System.system_time(:millisecond)

    format(<<millis::48, 7::4, rand_a::12, 2::2, rand_b::62>>)
  end

  @doc "A random UUIDv4."
  @spec uuid4() :: String.t()
  defdelegate uuid4, to: UUID

  @doc "A UUIDv1 (time and node based)."
  @spec uuid1() :: String.t()
  defdelegate uuid1, to: UUID

  @doc "A name-based UUIDv3 (MD5). `namespace` is `:dns`, `:url`, `:oid`, `:x500` or a UUID."
  @spec uuid3(atom() | String.t(), String.t()) :: String.t()
  defdelegate uuid3(namespace, name), to: UUID

  @doc "A name-based UUIDv5 (SHA-1). `namespace` is `:dns`, `:url`, `:oid`, `:x500` or a UUID."
  @spec uuid5(atom() | String.t(), String.t()) :: String.t()
  defdelegate uuid5(namespace, name), to: UUID

  defp format(
         <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
           e::binary-size(6)>>
       ) do
    [a, b, c, d, e] |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  # ── The identity string ───────────────────────────────────────────────────

  @doc """
  Join identity parts into the identity string. One part is returned as text unchanged; several
  are escaped and joined with `:`.

      iex> DDD.Identity.encode(["order-7"])
      "order-7"
      iex> DDD.Identity.encode(["t1", "sku-9"])
      "t1:sku-9"
  """
  @spec encode([term()]) :: String.t()
  def encode([single]), do: to_string(single)

  def encode(parts) when is_list(parts) do
    Enum.map_join(parts, ":", fn part ->
      part |> to_string() |> String.replace("\\", "\\\\") |> String.replace(":", "\\:")
    end)
  end

  @doc """
  Split a composite identity string back into its parts (the inverse of `encode/1`), also when a
  part itself contains a `:`.

      iex> DDD.Identity.decode("t1:sku-9")
      ["t1", "sku-9"]
      iex> ["a:b", "c"] |> DDD.Identity.encode() |> DDD.Identity.decode()
      ["a:b", "c"]
  """
  @spec decode(String.t()) :: [String.t()]
  def decode(string) when is_binary(string), do: decode(string, "", [])

  defp decode("", current, parts), do: Enum.reverse([current | parts])

  defp decode("\\" <> <<char::utf8, rest::binary>>, current, parts),
    do: decode(rest, current <> <<char::utf8>>, parts)

  defp decode(":" <> rest, current, parts), do: decode(rest, "", [current | parts])

  defp decode(<<char::utf8, rest::binary>>, current, parts),
    do: decode(rest, current <> <<char::utf8>>, parts)

  @doc """
  Build the identity string for `module` from a map or keyword list holding its parts. Raises
  `ArgumentError` when a part is missing or `nil`.
  """
  @spec build(module(), map() | keyword()) :: String.t()
  def build(module, parts) do
    parts = if is_list(parts), do: Map.new(parts), else: parts

    values =
      for {name, _type, _opts} <- module.__ddd_identity__() do
        case Map.get(parts, name) do
          nil ->
            raise ArgumentError, "#{inspect(module)} identity part #{inspect(name)} is missing"

          value ->
            value
        end
      end

    encode(values)
  end

  @doc """
  The identity string of an entity instance, for naming it in an error, or `nil` when it has
  none or can't be told (a part is missing or has no text form). Never raises.
  """
  @spec id_of(term()) :: String.t() | nil
  def id_of(%{__struct__: module} = struct) do
    with true <- function_exported?(module, :__ddd_identity__, 0),
         [_ | _] = parts <- module.__ddd_identity__(),
         values = Enum.map(parts, fn {name, _type, _opts} -> Map.get(struct, name) end),
         false <- Enum.any?(values, &is_nil/1) do
      encode(values)
    else
      _ -> nil
    end
  rescue
    # A part that is not text-like (a mistyped value on its way to being rejected).
    _ -> nil
  end

  def id_of(_other), do: nil

  @doc """
  The value a repository stores an entity under: the field value for a single-field identity,
  the identity string for a composite one. `nil` for a struct without identity.
  """
  @spec key(struct()) :: term()
  def key(%{__struct__: module} = struct) do
    case module.__ddd_identity__() do
      [] -> nil
      [{name, _type, _opts}] -> Map.get(struct, name)
      _composite -> module.identity(struct)
    end
  end

  @doc false
  # The types a part of a composite identity may have.
  def composite_type?(type), do: type in @composite_types or match?({:enum, _}, type)
end
