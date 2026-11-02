defmodule DDD.EventBus do
  @moduledoc """
  Simple in-process pub/sub event bus.

  In production replace with Phoenix.PubSub, Broadway, or a message broker.

  ## Usage

      DDD.EventBus.subscribe(MyApp.Events.OrderPlaced, MyApp.Handlers.SendEmail)
      DDD.EventBus.publish(event)

      defmodule MyApp.Handlers.SendEmail do
        def handle(%MyApp.Events.OrderPlaced{} = event) do
          MyApp.Mailer.send_confirmation(event.customer_id)
        end
      end
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  def init(state), do: {:ok, state}

  @doc "Subscribe a handler module to an event type. Subscribing twice has no extra effect."
  def subscribe(event_module, handler_module) do
    GenServer.call(__MODULE__, {:subscribe, event_module, handler_module})
  end

  @doc "Handler modules subscribed to an event type, in subscription order."
  def handlers_for(event_module) do
    GenServer.call(__MODULE__, {:handlers_for, event_module})
  end

  @doc "Remove a handler's subscription to an event type."
  def unsubscribe(event_module, handler_module) do
    GenServer.call(__MODULE__, {:unsubscribe, event_module, handler_module})
  end

  @doc "Publish a single domain event."
  def publish(event), do: GenServer.cast(__MODULE__, {:publish, event})

  @doc "Publish a list of domain events."
  def publish_all(events) when is_list(events), do: Enum.each(events, &publish/1)

  def handle_call({:subscribe, event_module, handler_module}, _from, state) do
    handlers = Map.get(state, event_module, [])
    {:reply, :ok, Map.put(state, event_module, Enum.uniq([handler_module | handlers]))}
  end

  def handle_call({:handlers_for, event_module}, _from, state) do
    {:reply, state |> Map.get(event_module, []) |> Enum.reverse(), state}
  end

  def handle_call({:unsubscribe, event_module, handler_module}, _from, state) do
    handlers = state |> Map.get(event_module, []) |> List.delete(handler_module)
    {:reply, :ok, Map.put(state, event_module, handlers)}
  end

  def handle_cast({:publish, event}, state) do
    handlers = Map.get(state, event.__struct__, [])

    Logger.debug(
      "[event_bus] #{inspect(event.__struct__)} -> #{length(handlers)} handler(s): " <>
        Enum.map_join(handlers, ", ", &inspect/1)
    )

    Enum.each(handlers, fn handler -> Task.start(fn -> handler.handle(event) end) end)
    {:noreply, state}
  end
end
