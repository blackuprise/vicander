defmodule DDD.Type.Json do
  @moduledoc """
  Ecto type behind the `:json` field type: any JSON term (map or list) in a `jsonb` column.
  Ecto's own `:map` refuses lists.
  """
  use Ecto.Type

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}
  def cast(_), do: :error

  @impl Ecto.Type
  def load(value), do: {:ok, value}

  @impl Ecto.Type
  def dump(value) when is_map(value) or is_list(value), do: {:ok, value}
  def dump(_), do: :error
end
