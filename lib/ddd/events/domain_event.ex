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

  A field is `field name, type, opts`. The type says how the value is stored in the outbox and
  how it comes back to the handler (`DDD.Type`: an atom, an enum, a Decimal, a date and a
  datetime survive the round trip). Options: `default: value` and `sensitive: true`, which
  leaves the field out of `inspect/1` (logs, crash reports, IEx) but not out of the stored
  payload.

  An event that changed in a way old rows can't be read as is gets a new module
  (`OrderPlacedV2`) instead of a new meaning for an old field name.
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

  defmacro field(name, type, opts \\ []) do
    quote do
      @event_fields [{unquote(name), unquote(type), unquote(opts)} | @event_fields]
    end
  end

  require Logger

  @doc false
  # The payload of an outbox row: the event's fields, each dumped as its declared type says
  # (an atom as text, a Decimal as text, a date as ISO 8601, ...), so that what is stored does not
  # depend on how a JSON encoder happens to treat a term. A value that does not fit its type is
  # stored as it is.
  def dump_payload(%module{} = event) do
    types = types(module)

    event
    |> Map.from_struct()
    |> Map.new(fn {key, value} ->
      case types do
        %{^key => type} -> {key, dump_field(type, value)}
        _ -> {key, value}
      end
    end)
  end

  @doc false
  # The inverse, for the payload of an outbox row whose keys are already atoms: each declared
  # field is loaded as its type says. A row that was written before a field had its type, or by
  # hand, keeps the stored value of a field that does not load, so the event is still delivered.
  def load_payload(module, payload) when is_map(payload) do
    types = types(module)

    Map.new(payload, fn {key, value} ->
      case types do
        %{^key => type} -> {key, load_field(module, key, type, value)}
        _ -> {key, value}
      end
    end)
  end

  defp dump_field(type, value) do
    DDD.Type.json_dump(type, value)
  rescue
    _ -> value
  end

  defp load_field(module, key, type, value) do
    DDD.Type.json_load(type, value)
  rescue
    exception ->
      Logger.warning(
        "[event] #{inspect(module)}.#{key}: #{inspect(value)} does not load as " <>
          "#{inspect(type)} (#{Exception.message(exception)}); keeping it as stored"
      )

      value
  end

  defp types(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__event_types__, 0),
      do: Map.new(module.__event_types__()),
      else: %{}
  end

  defmacro __before_compile__(env) do
    types =
      env.module
      |> Module.get_attribute(:event_fields)
      |> Enum.reverse()
      |> Enum.map(fn {name, type, _opts} -> {name, type} end)

    sensitive =
      for {name, _type, opts} <- Module.get_attribute(env.module, :event_fields),
          opts[:sensitive],
          do: name

    quote do
      @doc false
      # The declared type of each field of the event: [{name, type}].
      def __event_types__, do: unquote(Macro.escape(types))

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
        (base_fields ++ Enum.map(@event_fields, fn {name, _type, opts} -> {name, opts} end))
        |> Enum.reverse()
        |> Enum.map(fn {name, opts} -> {name, Keyword.get(opts, :default, nil)} end)

      # A `sensitive: true` field is left out of `inspect/1` (logs, crash reports, IEx).
      # It is still in the struct, and in the outbox payload.
      if unquote(sensitive) != [], do: @derive({Inspect, except: unquote(sensitive)})

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
          |> Map.put_new_lazy(:event_id, fn -> DDD.Identity.generate() end)
          |> Map.put_new(:occurred_at, now)
          |> Map.put_new(:created_at, now)

        struct(__MODULE__, attrs)
      end

      defoverridable event_name: 0
    end
  end
end
