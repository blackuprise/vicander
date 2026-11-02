defmodule DDD.BoundedContext do
  @moduledoc """
  Macro for declaring a Bounded Context.

  ## Usage

      defmodule MyApp.Ordering do
        use DDD.BoundedContext

        bounded_context name: "Ordering",
                        description: "Order lifecycle from placement to fulfillment"

        context_api do
          exposes MyApp.PlaceOrderUseCase
        end

        publishes_events [MyApp.Events.OrderPlaced, MyApp.Events.OrderConfirmed]

        subscribes_to [
          {MyApp.Inventory.Events.StockReserved, MyApp.Ordering.Handlers.StockHandler}
        ]
      end
  """

  defmacro __using__(_opts) do
    quote do
      import DDD.BoundedContext,
        only: [
          bounded_context: 1,
          context_api: 1,
          exposes: 1,
          publishes_events: 1,
          subscribes_to: 1
        ]

      @bc_name nil
      @bc_description nil
      @bc_exposed_apis []
      @bc_published_events []
      @bc_subscriptions []
      @before_compile DDD.BoundedContext
    end
  end

  defmacro bounded_context(opts) do
    quote do
      @bc_name Keyword.get(unquote(opts), :name, inspect(__MODULE__))
      @bc_description Keyword.get(unquote(opts), :description, "")
    end
  end

  defmacro context_api(do: block), do: quote(do: unquote(block))
  defmacro exposes(module), do: quote(do: @bc_exposed_apis([unquote(module) | @bc_exposed_apis]))
  defmacro publishes_events(list), do: quote(do: @bc_published_events(unquote(list)))
  defmacro subscribes_to(list), do: quote(do: @bc_subscriptions(unquote(list)))

  defmacro __before_compile__(_env) do
    quote do
      def __bc_name__, do: @bc_name
      def __bc_description__, do: @bc_description
      def __bc_apis__, do: Enum.reverse(@bc_exposed_apis)
      def __bc_published_events__, do: @bc_published_events
      def __bc_subscriptions__, do: @bc_subscriptions

      def setup_subscriptions do
        Enum.each(@bc_subscriptions, fn {event_module, handler_module} ->
          DDD.EventBus.subscribe(event_module, handler_module)
        end)
      end

      def describe do
        %{
          name: @bc_name,
          description: @bc_description,
          apis: Enum.reverse(@bc_exposed_apis),
          publishes: @bc_published_events,
          subscribes: Enum.map(@bc_subscriptions, &elem(&1, 0))
        }
      end
    end
  end
end
