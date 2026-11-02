defmodule DDD.Aggregate do
  @moduledoc """
  Behaviour and macros for Domain-Driven Design Aggregate Roots.

  An aggregate is a consistency boundary: the root is the only entry point, and
  nested entities are stored inside it (one row for the whole aggregate).
  Aggregates collect domain events; the repository persists them with the state.

  Same rules as `DDD.Entity` (field rules, `invariant`, `defop`, sealing).

  ## Usage

      defmodule MyApp.Order do
        use DDD.Aggregate

        aggregate do
          identity :id,          :uuid
          field    :customer_id, :string, required: true
          field    :status,      :atom, default: :pending
          field    :items,       {:list, MyApp.OrderItem}, default: []

          invariant MyApp.Specs.MaxItems, max: 10
        end

        defop confirm(order), requires: MyApp.Specs.OrderIsPending do
          order
          |> Map.put(:status, :confirmed)
          |> emit_event(MyApp.Events.OrderConfirmed.new(%{order_id: order.id}))
        end
      end

  Events emitted inside a `defop` are discarded when the result is invalid.

  Nested types: `{:list, EntityModule}` and `{:one, EntityModule}`.
  """

  @callback new(attrs :: map() | keyword()) :: {:ok, struct()} | {:error, DDD.Error.t()}
  @callback update(aggregate :: struct(), changes :: map() | keyword() | (struct() -> struct())) ::
              {:ok, struct()} | {:error, DDD.Error.t()}

  defmacro __using__(_opts) do
    quote do
      use DDD.Schema, kind: :aggregate, behaviour: DDD.Aggregate
      import DDD.Aggregate, only: [aggregate: 1]
    end
  end

  defmacro aggregate(do: block) do
    quote do
      require DDD.Schema
      DDD.Schema.define_struct(unquote(block))
    end
  end
end
