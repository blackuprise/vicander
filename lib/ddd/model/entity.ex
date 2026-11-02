defmodule DDD.Entity do
  @moduledoc """
  Behaviour and macros for Domain-Driven Design Entities.

  Entities have a unique identity that persists through state changes. Two
  entities with the same identity are the same entity, whatever their other
  attributes.

  An entity can never exist in an invalid state: `new/1`, `update/2`, `validate/1`
  and every `defop` check field rules and specification invariants.

  ## Usage

      defmodule MyApp.OrderItem do
        use DDD.Entity

        entity do
          identity :id,       :uuid
          field    :sku,      :string, required: true
          field    :quantity, :integer, default: 1
          field    :status,   :atom, default: :open

          invariant MyApp.Specs.SkuKnown
          invariant MyApp.Specs.PositiveQuantity
        end

        # `requires:` states the business rule by name; it runs before the body.
        defop cancel(item), requires: MyApp.Specs.ItemIsOpen do
          %{item | status: :cancelled}
        end
      end

      {:ok, item} = MyApp.OrderItem.new(sku: "WIDGET-001", quantity: 3)
      {:ok, item} = MyApp.OrderItem.update(item, quantity: 5)
      {:ok, item} = MyApp.OrderItem.cancel(item)

  Field options: `:default`, `:required`. Business rules are specifications
  (see `DDD.Specification`): `invariant SpecModule, opts` for what must always hold, and
  `defop name(entity), requires: SpecModule` for what must hold before an operation may run.
  `validate field, fun, message: ...` is a nameless shortcut for a throwaway one-liner
  (skipped for `nil`).

  Failures are `{:error, %DDD.Error{}}`.
  """

  @callback new(attrs :: map() | keyword()) :: {:ok, struct()} | {:error, DDD.Error.t()}
  @callback update(entity :: struct(), changes :: map() | keyword() | (struct() -> struct())) ::
              {:ok, struct()} | {:error, DDD.Error.t()}
  @callback same_identity?(a :: struct(), b :: struct()) :: boolean()

  defmacro __using__(_opts) do
    quote do
      use DDD.Schema, kind: :entity, behaviour: DDD.Entity
      import DDD.Entity, only: [entity: 1]
    end
  end

  defmacro entity(do: block) do
    quote do
      require DDD.Schema
      DDD.Schema.define_struct(unquote(block))
    end
  end
end
