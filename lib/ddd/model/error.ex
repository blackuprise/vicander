defmodule DDD.Error do
  @moduledoc """
  Structured error produced by the framework.

    * `:kind`       - `:business` (the domain said no; retrying gives the same answer) or
      `:infrastructure` (the system failed; retrying may succeed). Event handlers use it:
      a business error is a recorded rejection, an infrastructure error is retried.
    * `:entity`     - business entity (module) that produced the error
    * `:entity_id`  - the identity (`Entity.identity/1`) of the instance it happened to, or `nil`
      when there is none yet or it can't be told (a `new` call that is missing its identity)
    * `:operation`  - operation being run (`:new`, `:update`, `:validate` or a `defop` name)
    * `:code`       - machine-matchable code, e.g. `:validation_failed`
    * `:message`    - human-readable message
    * `:details`    - data produced by the rule that failed
    * `:violations` - list of `%{field, code, message, details}` when several rules failed
    * `:context`    - added by outer layers (running a command adds `:command`)
  """

  @type violation :: %{
          field: atom(),
          code: atom(),
          message: String.t(),
          details: map()
        }

  @type kind :: :business | :infrastructure

  @type t :: %__MODULE__{
          kind: kind(),
          entity: module() | nil,
          entity_id: String.t() | nil,
          operation: atom() | nil,
          code: atom(),
          message: String.t(),
          details: map(),
          violations: [violation()],
          context: map()
        }

  defstruct kind: :business,
            entity: nil,
            entity_id: nil,
            operation: nil,
            code: :unknown,
            message: "",
            details: %{},
            violations: [],
            context: %{}

  @doc "Build an error from a keyword list or map."
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc "Build a business error: the domain decided no. Never retried."
  @spec business(keyword() | map()) :: t()
  def business(attrs), do: attrs |> Map.new() |> Map.put(:kind, :business) |> new()

  @doc "Build an infrastructure error: the system failed. Retried by event handlers."
  @spec infrastructure(keyword() | map()) :: t()
  def infrastructure(attrs), do: attrs |> Map.new() |> Map.put(:kind, :infrastructure) |> new()

  @doc "True for business errors."
  @spec business?(t()) :: boolean()
  def business?(%__MODULE__{kind: kind}), do: kind == :business

  @doc "True for infrastructure errors."
  @spec infrastructure?(t()) :: boolean()
  def infrastructure?(%__MODULE__{kind: kind}), do: kind == :infrastructure

  @doc "Build a violation map (one failed rule)."
  @spec violation(atom(), atom(), String.t(), map()) :: violation()
  def violation(field, code, message, details \\ %{}),
    do: %{field: field, code: code, message: message, details: details}

  @doc "Build a `:validation_failed` error from a non-empty list of violations."
  @spec validation_failed(module(), atom(), [violation()], String.t() | nil) :: t()
  def validation_failed(entity, operation, violations, entity_id \\ nil) do
    %__MODULE__{
      entity: entity,
      entity_id: entity_id,
      operation: operation,
      code: :validation_failed,
      message: "#{inspect(entity)} failed validation (#{length(violations)} violation(s))",
      violations: violations
    }
  end

  @doc "All violation codes of an error (or `[code]` when there are no violations)."
  @spec codes(t()) :: [atom()]
  def codes(%__MODULE__{violations: [], code: code}), do: [code]
  def codes(%__MODULE__{violations: vs}), do: Enum.map(vs, & &1.code)

  @doc "True when the error, or any of its violations, has the given code."
  @spec has_code?(t(), atom()) :: boolean()
  def has_code?(%__MODULE__{} = error, code), do: code in codes(error)

  @doc "Merge extra context into the error."
  @spec put_context(t(), map() | keyword()) :: t()
  def put_context(%__MODULE__{context: ctx} = error, extra),
    do: %{error | context: Map.merge(ctx, Map.new(extra))}

  @doc """
  Convert any error reason into a `DDD.Error`, merging `context`.

  Errors pass through. Atoms and `{code, message}` tuples are wrapped as `:business`
  errors (a plain reason is the domain's answer). An exception becomes an `:infrastructure`
  error with code `:exception`. Anything else becomes `:unknown` (business) with the
  inspected reason in `details`.
  """
  @spec wrap(any(), map() | keyword()) :: t()
  def wrap(%__MODULE__{} = error, context), do: put_context(error, context)

  def wrap(%{__exception__: true} = exception, context),
    do: %__MODULE__{
      kind: :infrastructure,
      code: :exception,
      message: Exception.message(exception),
      details: %{exception: inspect(exception.__struct__)},
      context: Map.new(context)
    }

  def wrap(code, context) when is_atom(code),
    do: %__MODULE__{code: code, message: Atom.to_string(code), context: Map.new(context)}

  def wrap({code, message}, context) when is_atom(code) and is_binary(message),
    do: %__MODULE__{code: code, message: message, context: Map.new(context)}

  def wrap(other, context),
    do: %__MODULE__{
      code: :unknown,
      message: "unexpected error",
      details: %{reason: inspect(other)},
      context: Map.new(context)
    }

  @doc """
  Per-field map of messages (form style): `%{field => [message]}`.
  Errors without violations are reported under `:base`.
  """
  @spec to_map(t()) :: %{atom() => [String.t()]}
  def to_map(%__MODULE__{violations: [], message: message}), do: %{base: [message]}

  def to_map(%__MODULE__{violations: violations}) do
    Enum.reduce(violations, %{}, fn %{field: field, message: message}, acc ->
      Map.update(acc, field, [message], &(&1 ++ [message]))
    end)
  end
end
