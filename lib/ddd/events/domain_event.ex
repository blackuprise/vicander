defmodule DDD.DomainEvent do
  @moduledoc """
  Behaviour and macros for Domain Events.

  Domain Events represent meaningful things that happened in the domain.
  Named in past tense, they carry all data needed to understand the occurrence.

  ## Usage

      defmodule MyApp.Events.OrderPlaced do
        use DDD.DomainEvent

        domain_event do
          field :order_id,    :string
          field :customer_id, :string
        end
      end

      event = MyApp.Events.OrderPlaced.new(%{order_id: "123", customer_id: "c1"})
  """

  @callback event_name() :: String.t()

  defmacro __using__(_opts) do
    quote do
      import DDD.DomainEvent, only: [domain_event: 1, field: 2, field: 3]
      @behaviour DDD.DomainEvent
      @event_fields []
      @before_compile DDD.DomainEvent
    end
  end

  defmacro domain_event(do: block), do: quote(do: unquote(block))

  defmacro field(name, _type, opts \\ []) do
    quote do
      @event_fields [{unquote(name), unquote(opts)} | @event_fields]
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      # aggregate_type / aggregate_id link the event to the aggregate it came from;
      # `emit_event/2` fills them in.
      base_fields = [
        {:event_id, []},
        {:occurred_at, []},
        {:created_at, []},
        {:aggregate_type, []},
        {:aggregate_id, []}
      ]

      all_fields =
        (base_fields ++ @event_fields)
        |> Enum.reverse()
        |> Enum.map(fn {name, opts} -> {name, Keyword.get(opts, :default, nil)} end)

      defstruct all_fields

      @impl DDD.DomainEvent
      def event_name do
        __MODULE__ |> Module.split() |> List.last() |> Macro.underscore()
      end

      @doc "Build a new event with auto-populated event_id, occurred_at and created_at."
      def new(attrs \\ %{}) when is_map(attrs) or is_list(attrs) do
        attrs = if is_list(attrs), do: Map.new(attrs), else: attrs
        now = DateTime.utc_now()

        attrs =
          attrs
          |> Map.put_new_lazy(:event_id, fn -> UUID.uuid4() end)
          |> Map.put_new(:occurred_at, now)
          |> Map.put_new(:created_at, now)

        struct(__MODULE__, attrs)
      end

      defoverridable event_name: 0
    end
  end
end
