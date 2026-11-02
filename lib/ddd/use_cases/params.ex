defmodule DDD.Params do
  @moduledoc """
  The declared input of a use case: the fields, descriptions and validation that
  `DDD.Command` and `DDD.Query` share.

      command do
        description "Add an item to a todo list"

        field :list_id, :uuid, required: true, description: "The list to add to"
        field :title,   :string, required: true, description: "What needs doing"
        field :due_date, :date, description: "Optional; not in the past"
      end

  A field is `field name, type, opts`. The type is any `DDD.Type`. Options: `required: true`,
  `default: value` and `description: "..."`. `new/1` reports every missing required field and
  every value of the wrong type at once, as a `DDD.Error` with a violation per field.

  The declaration is also readable by tools: `__description__/0` and `__params__/0`
  (`[{name, type, opts}]`), which is how the MCP server builds a tool's input schema.
  """

  defmacro __using__(_opts) do
    quote do
      import DDD.Params, only: [field: 2, field: 3, description: 1]
      @params_fields []
      @params_description nil
      @before_compile DDD.Params
    end
  end

  @doc false
  # Runs the block of `command do ... end` / `query do ... end` and defines the struct.
  defmacro define_struct(block) do
    quote do
      unquote(block)

      defstruct @params_fields
                |> Enum.reverse()
                |> Enum.map(fn {name, _type, opts} -> {name, Keyword.get(opts, :default)} end)
    end
  end

  @doc "Describe the use case in a sentence."
  defmacro description(text) do
    quote do
      @params_description unquote(text)
    end
  end

  @doc "Declare a field: `field name, type, required: true, default: ..., description: \"...\"`."
  defmacro field(name, type, opts \\ []) do
    quote do
      @params_fields [
        {unquote(name), DDD.Type.normalize!(unquote(type)), unquote(opts)} | @params_fields
      ]
    end
  end

  defmacro __before_compile__(env) do
    fields = env.module |> Module.get_attribute(:params_fields) |> Enum.reverse()

    typed_fields =
      for {name, type, opts} <- fields do
        spec = typespec(type)

        {name,
         if(Keyword.get(opts, :required, false), do: spec, else: quote(do: unquote(spec) | nil))}
      end

    quote do
      @typedoc "The declared struct, one key per `field`."
      @type t :: %__MODULE__{unquote_splicing(typed_fields)}

      @doc "Build and validate from a map or keyword list."
      def new(attrs) when is_map(attrs) or is_list(attrs),
        do: DDD.Params.build(__MODULE__, Map.new(attrs))

      @doc false
      def __description__, do: @params_description

      @doc false
      def __params__, do: Enum.reverse(@params_fields)
    end
  end

  # The typespec (quoted) for a `DDD.Type`, used to generate the struct's `t()` type so editors
  # and Dialyzer know the shape of `command.list_id` and friends.
  defp typespec(type) when type in [:string, :text, :uuid], do: quote(do: String.t())
  defp typespec(:binary), do: quote(do: binary())
  defp typespec(:integer), do: quote(do: integer())
  defp typespec(:float), do: quote(do: number())
  defp typespec(:boolean), do: quote(do: boolean())
  defp typespec(:atom), do: quote(do: atom())
  defp typespec(:decimal), do: quote(do: Decimal.t())
  defp typespec(:date), do: quote(do: Date.t())
  defp typespec(:time), do: quote(do: Time.t())
  defp typespec(:naive_datetime), do: quote(do: NaiveDateTime.t())
  defp typespec(type) when type in [:datetime, :datetime_usec], do: quote(do: DateTime.t())
  defp typespec(:map), do: quote(do: map())
  defp typespec(:json), do: quote(do: map() | list())
  defp typespec(:list), do: quote(do: list())
  defp typespec({:array, inner}), do: [typespec(inner)]
  defp typespec({:map, inner}), do: quote(do: %{optional(term()) => unquote(typespec(inner))})
  defp typespec({:ref, _module}), do: quote(do: term())
  defp typespec({:one, module}), do: {{:., [], [module, :t]}, [], []}
  defp typespec({:list, module}), do: [typespec({:one, module})]

  defp typespec({:enum, values}),
    do: values |> Enum.reverse() |> Enum.reduce(fn v, acc -> {:|, [], [v, acc]} end)

  @doc false
  def build(module, attrs) do
    violations =
      for {name, type, opts} <- module.__params__(),
          violation <- check(name, type, Keyword.get(opts, :required, false), attrs),
          do: violation

    case violations do
      [] -> {:ok, struct(module, attrs)}
      violations -> {:error, DDD.Error.validation_failed(module, :new, violations)}
    end
  end

  defp check(name, type, required?, attrs) do
    case Map.get(attrs, name) do
      nil when required? ->
        [DDD.Error.violation(name, :required, "is required")]

      nil ->
        []

      value ->
        if DDD.Type.valid?(type, value),
          do: [],
          else: [
            DDD.Error.violation(
              name,
              :invalid_type,
              "must be #{DDD.Type.describe(type)}",
              %{type: type}
            )
          ]
    end
  end
end
