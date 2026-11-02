defmodule DDD.AggregateTest do
  use ExUnit.Case, async: true

  defmodule Events.OrderPlaced do
    use DDD.DomainEvent

    domain_event do
      field :order_id, :string
      field :customer_id, :string
    end
  end

  defmodule Events.OrderConfirmed do
    use DDD.DomainEvent

    domain_event do
      field :order_id, :string
    end
  end

  defmodule HasItems do
    use DDD.Specification, field: :items

    def check(%{items: []}, _opts), do: {:error, :no_items, "needs items"}
    def check(_order, _opts), do: :ok
  end

  defmodule Order do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :customer_id, :string, required: true
      field :status, :atom, default: :pending
      field :items, :list, default: []
    end

    def place(attrs) do
      with {:ok, order} <- new(attrs) do
        {:ok,
         emit_event(
           order,
           Events.OrderPlaced.new(%{order_id: order.id, customer_id: order.customer_id})
         )}
      end
    end

    defop add_item(%{status: :pending} = order, item), do: %{order | items: [item | order.items]}

    defop confirm(%{status: :pending} = order) do
      %{order | status: :confirmed}
      |> emit_event(Events.OrderConfirmed.new(%{order_id: order.id}))
    end

    defop confirm_if_ready(%{status: :pending} = order) do
      %{order | status: :confirmed}
      |> emit_event(Events.OrderConfirmed.new(%{order_id: order.id}))
      |> then(fn confirmed ->
        if confirmed.items == [], do: {:error, {:no_items, "needs items"}}, else: confirmed
      end)
    end
  end

  defmodule Strict do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :items, :list, default: []
      invariant HasItems
    end

    defop touch(strict) do
      strict
      |> Map.put(:items, [])
      |> emit_event(Events.OrderConfirmed.new(%{order_id: strict.id}))
    end
  end

  describe "new/1 and update/2" do
    test "build sealed aggregates" do
      assert {:ok, order} = Order.new(customer_id: "c1")
      assert order.status == :pending
      assert order.__pending_events__ == []
      assert {:ok, updated} = Order.update(order, status: :confirmed)
      assert updated.status == :confirmed
      assert DDD.Schema.sealed?(updated)
    end

    test "validation applies to aggregates too" do
      assert {:error, error} = Order.new(%{})
      assert DDD.Error.codes(error) == [:required]
      assert error.entity == Order
    end

    test "aggregate invariants" do
      assert {:error, error} = Strict.new(%{})
      assert DDD.Error.has_code?(error, :no_items)
    end
  end

  describe "events" do
    test "emit_event/2 collects events without breaking the seal" do
      {:ok, order} = Order.place(%{customer_id: "cust_1"})
      assert [%Events.OrderPlaced{customer_id: "cust_1"}] = order.__pending_events__
      assert {:ok, order} = Order.validate(order)
      assert DDD.Schema.sealed?(order)
    end

    test "emit_event/2 links the event to the aggregate (type and id)" do
      {:ok, order} = Order.place(%{customer_id: "cust_1"})
      [event] = order.__pending_events__

      assert event.aggregate_type == "DDD.AggregateTest.Order"
      assert event.aggregate_id == order.id
      assert %DateTime{} = event.created_at
    end

    test "events emitted inside a defop are linked too" do
      {:ok, order} = Order.new(customer_id: "c1")
      {:ok, confirmed} = Order.confirm(order)

      assert [%{aggregate_type: "DDD.AggregateTest.Order", aggregate_id: id}] =
               confirmed.__pending_events__

      assert id == order.id
    end

    test "emit_event/2 leaves things that are not DDD events alone" do
      {:ok, order} = Order.new(customer_id: "c1")
      order = Order.emit_event(order, %{just: "a map"})
      assert order.__pending_events__ == [%{just: "a map"}]
    end

    test "aggregates also get created_at and updated_at" do
      {:ok, order} = Order.new(customer_id: "c1")
      assert %DateTime{} = order.created_at
      assert order.created_at == order.updated_at
    end

    test "pop_events/1 returns the events and clears them" do
      {:ok, order} = Order.place(%{customer_id: "cust_1"})
      {events, cleared} = Order.pop_events(order)
      assert length(events) == 1
      assert cleared.__pending_events__ == []
      assert DDD.Schema.sealed?(cleared)
    end

    test "the pending events are sealed: replacing them by hand breaks the seal" do
      {:ok, order} = Order.place(%{customer_id: "cust_1"})
      forged = %{order | __pending_events__: [%{forged: true}]}
      refute DDD.Schema.sealed?(forged)

      cleared = %{order | __pending_events__: []}
      refute DDD.Schema.sealed?(cleared)

      # The sanctioned ways keep it.
      assert DDD.Schema.sealed?(Order.emit_event(order, %{another: true}))
      assert DDD.Schema.sealed?(elem(Order.pop_events(order), 1))
    end

    test "a defop and update refuse an aggregate whose events were replaced" do
      {:ok, order} = Order.new(customer_id: "c1")
      forged = %{order | __pending_events__: [%{forged: true}]}

      assert {:error, %DDD.Error{code: :unsealed}} = Order.confirm(forged)
      assert {:error, %DDD.Error{code: :unsealed}} = Order.update(forged, customer_id: "c2")
    end

    test "validate/1 does not seal events that were put there by hand" do
      {:ok, order} = Order.place(%{customer_id: "cust_1"})
      forged = %{order | __pending_events__: [%{forged: true}]}

      assert {:error, %DDD.Error{code: :unsealed, operation: :validate}} = Order.validate(forged)

      # No events, or the sealed original: nothing to be suspicious of.
      assert {:ok, _} = Order.validate(%{order | customer_id: "c9", __pending_events__: []})
      assert {:ok, _} = Order.validate(order)
    end

    test "emit_event/2 on an aggregate an operation is still building leaves it unsealed" do
      {:ok, order} = Order.new(customer_id: "c1")
      building = %{order | customer_id: "c2"}
      refute DDD.Schema.sealed?(building)

      emitted = Order.emit_event(building, %{x: 1})
      refute DDD.Schema.sealed?(emitted)
      assert emitted.__pending_events__ == [%{x: 1}]
    end

    test "a defop keeps events when the result is valid" do
      {:ok, order} = Order.new(customer_id: "c1")
      assert {:ok, confirmed} = Order.confirm(order)
      assert [%Events.OrderConfirmed{}] = confirmed.__pending_events__
    end

    test "a defop discards events when the result is invalid" do
      {:ok, strict} = Strict.new(items: [1])
      assert {:error, error} = Strict.touch(strict)
      assert DDD.Error.has_code?(error, :no_items)
    end

    test "a refused defop returns the error and no events" do
      {:ok, order} = Order.new(customer_id: "c1")
      assert {:error, %{code: :no_items}} = Order.confirm_if_ready(order)
    end
  end

  describe "state transitions" do
    test "add_item then confirm" do
      {:ok, order} = Order.new(customer_id: "c1")
      {:ok, order} = Order.add_item(order, %{sku: "W001"})
      assert {:ok, %{status: :confirmed}} = Order.confirm(order)
    end

    test "an operation from the wrong state reports the state" do
      {:ok, order} = Order.new(customer_id: "c1")
      {:ok, confirmed} = Order.confirm(order)

      assert {:error,
              %{code: :invalid_operation, operation: :confirm, details: %{state: :confirmed}}} =
               Order.confirm(confirmed)
    end
  end
end
