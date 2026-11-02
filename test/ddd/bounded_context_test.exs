defmodule DDD.BoundedContextTest do
  use ExUnit.Case, async: true

  defmodule Happened do
    use DDD.DomainEvent

    domain_event do
      field :what, :string
      field :where, :string, default: "here"
    end
  end

  defmodule Handler do
    def handle(event) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil), do: send(pid, {:handled, event})
    end
  end

  defmodule Pricing do
    use DDD.DomainService
  end

  defmodule Ordering do
    use DDD.BoundedContext

    bounded_context(name: "Ordering", description: "Order lifecycle")

    context_api do
      exposes(DDD.BoundedContextTest.Pricing)
    end

    publishes_events([DDD.BoundedContextTest.Happened])
    subscribes_to([{DDD.BoundedContextTest.Happened, DDD.BoundedContextTest.Handler}])
  end

  defmodule Unnamed do
    use DDD.BoundedContext
    bounded_context([])
  end

  describe "BoundedContext" do
    test "describes itself" do
      assert Ordering.__bc_name__() == "Ordering"
      assert Ordering.__bc_description__() == "Order lifecycle"
      assert Ordering.__bc_apis__() == [Pricing]
      assert Ordering.__bc_published_events__() == [Happened]
      assert Ordering.__bc_subscriptions__() == [{Happened, Handler}]

      assert Ordering.describe() == %{
               name: "Ordering",
               description: "Order lifecycle",
               apis: [Pricing],
               publishes: [Happened],
               subscribes: [Happened]
             }
    end

    test "the name defaults to the module name" do
      assert Unnamed.__bc_name__() == "DDD.BoundedContextTest.Unnamed"
    end

    test "setup_subscriptions/0 wires handlers onto the event bus" do
      :persistent_term.put({Handler, :pid}, self())
      assert :ok = Ordering.setup_subscriptions()

      event = Happened.new(what: "ordered")
      DDD.EventBus.publish(event)
      assert_receive {:handled, ^event}
    end
  end

  describe "DomainService" do
    test "is marked" do
      assert Pricing.__ddd_type__() == :domain_service
    end
  end

  describe "DomainEvent" do
    test "new/1 fills id, time and defaults" do
      event = Happened.new(%{what: "x"})
      assert String.length(event.event_id) == 36
      assert %DateTime{} = event.occurred_at
      assert event.where == "here"
      assert Happened.event_name() == "happened"
    end

    test "events carry created_at, and are not linked to an aggregate until emitted" do
      event = Happened.new(what: "x")
      assert %DateTime{} = event.created_at
      assert event.created_at == event.occurred_at
      assert event.aggregate_type == nil
      assert event.aggregate_id == nil

      linked = Happened.new(what: "x", aggregate_type: "My.Order", aggregate_id: "42")
      assert {linked.aggregate_type, linked.aggregate_id} == {"My.Order", "42"}
    end

    test "publish_all/1 publishes each event" do
      :persistent_term.put({Handler, :pid}, self())
      DDD.EventBus.subscribe(Happened, Handler)
      a = Happened.new(what: "a")
      b = Happened.new(what: "b")
      DDD.EventBus.publish_all([a, b])
      assert_receive {:handled, ^a}
      assert_receive {:handled, ^b}
    end

    test "events without handlers are ignored" do
      defmodule Lonely do
        use DDD.DomainEvent

        domain_event do
        end
      end

      assert :ok = DDD.EventBus.publish(Lonely.new())
    end
  end
end
