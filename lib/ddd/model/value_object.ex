defmodule DDD.ValueObject do
  @moduledoc """
  Behaviour and macros for Domain-Driven Design Value Objects.

  Value objects are immutable, identity-less and defined entirely by their
  attributes: two value objects with the same attributes are equal. They are
  built only through `new/1`, which runs field rules and specification invariants.

  ## Usage

      defmodule MyApp.Money do
        use DDD.ValueObject

        value_object do
          field :amount,   :decimal, required: true
          field :currency, :string,  required: true

          validate :amount,   &(Decimal.compare(&1, 0) == :gt), message: "must be positive"
          validate :currency, &(String.length(&1) == 3),        message: "must be 3-letter ISO code"
        end
      end

      {:ok, money} = MyApp.Money.new(amount: Decimal.new("10.00"), currency: "USD")
  """

  @callback new(attrs :: map() | keyword()) :: {:ok, struct()} | {:error, DDD.Error.t()}
  @callback equals?(a :: struct(), b :: struct()) :: boolean()

  defmacro __using__(_opts) do
    quote do
      use DDD.Schema, kind: :value_object, behaviour: DDD.ValueObject
      import DDD.ValueObject, only: [value_object: 1]
    end
  end

  defmacro value_object(do: block) do
    quote do
      require DDD.Schema
      DDD.Schema.define_struct(unquote(block))
    end
  end
end
