defmodule DDD.Specification do
  @moduledoc """
  Specification pattern: a named, reusable, composable business rule.

  A specification is a pure function of an entity (no database access).

      defmodule MyApp.Specs.MaxOpenItems do
        use DDD.Specification, field: :items

        def check(%{items: items}, opts) do
          max = Keyword.fetch!(opts, :max)

          if Enum.count(items, &(&1.status == :open)) <= max,
            do: :ok,
            else: {:error, :too_many_open_items, "max \#{max} open items", %{max: max}}
        end
      end

  `check/2` returns `:ok`, `{:error, code, message}` or `{:error, code, message, details}`.
  `use DDD.Specification` also derives `satisfied_by?/2`. `:field` (default `:base`) is the
  field a failure is reported under.

  ## Value specs

  A spec that judges one field's value is declared with `scope: :value` and bound to the field
  where it is attached, so one spec serves any field and nothing relies on a naming convention:

      defmodule MyApp.Specs.ValidEmail do
        use DDD.Specification, scope: :value

        def check(email, _opts), do: ...      # the value, never nil
      end

      invariant MyApp.Specs.ValidEmail, on: :email

  Failures are reported under the `on:` field. A missing `on:`, or a field the entity doesn't
  have, is a compile error in `invariant` (and an `ArgumentError` when evaluated directly).

  Entities attach specs two ways:

    * `invariant MyApp.Specs.MaxOpenItems, max: 10` - must hold after every change.
    * `defop name(entity, ...), requires: SomeSpec` - must hold *before* the operation may run
      (a precondition). The operation's other arguments arrive in `opts[:args]`, so a rule can
      depend on them: `def check(list, opts)` with `[item_id] = Keyword.fetch!(opts, :args)`.

  ## Composition

  Specs combine with `all_of/1`, `any_of/1` and `not_spec/1`, which return
  composite spec values accepted everywhere a spec module is:

      spec = DDD.Specification.all_of([NotBlank, {MaxLength, max: 100}])
      DDD.Specification.evaluate(spec, entity)

  `all_of` returns the first failure, `any_of` returns the last failure when
  every branch fails.

  ## Searching with a specification

  A specification is a function of an entity, so the database can't run it. A spec that also
  defines `to_filter/1` can be used to *find* the entities that satisfy it, by translating it
  to a `DDD.Filter`:

      defmodule MyApp.Specs.Overdue do
        use DDD.Specification

        def check(%{due: due}, _opts), do: ...      # the in-memory rule

        @impl DDD.Specification
        def to_filter(_opts), do: {:due, {:lt, Date.utc_today()}}   # the same rule, as SQL
      end

      MyApp.TodoRepository.list(spec: DDD.Specification.all_of([Overdue, {Owned, owner: id}]))

  `all_of`, `any_of` and `not_spec` translate to `{:and, _}`, `{:or, _}` and `{:not, _}`. Keep
  `check/2` and `to_filter/1` in step; a test that runs both over the same rows is cheap.
  """

  @type result :: :ok | {:error, atom(), String.t()} | {:error, atom(), String.t(), map()}
  @type spec ::
          module()
          | {module(), keyword()}
          | {:all_of, [spec()]}
          | {:any_of, [spec()]}
          | {:not, spec()}

  @callback check(entity_or_value :: term(), opts :: keyword()) :: result()

  @doc "The same rule as a `DDD.Filter`, so the database can search with it. Optional."
  @callback to_filter(opts :: keyword()) :: term()
  @optional_callbacks to_filter: 1

  defmacro __using__(opts) do
    field = Keyword.get(opts, :field, :base)
    scope = Keyword.get(opts, :scope, :entity)

    unless scope in [:entity, :value],
      do: raise(ArgumentError, "scope must be :entity or :value, got: #{inspect(scope)}")

    quote do
      @behaviour DDD.Specification

      @doc false
      def __spec_field__, do: unquote(field)

      @doc false
      def __spec_scope__, do: unquote(scope)

      @doc "True when the entity satisfies this specification."
      def satisfied_by?(entity, opts \\ []),
        do: DDD.Specification.evaluate(__MODULE__, entity, opts) == :ok
    end
  end

  @doc """
  Translate a spec to a `DDD.Filter` expression (see "Searching with a specification").

  Raises `ArgumentError` for a spec module without `to_filter/1`: it can be checked in memory
  but not searched for.
  """
  @spec to_filter(spec(), keyword()) :: term()
  def to_filter(spec, opts \\ [])
  def to_filter({:all_of, specs}, opts), do: {:and, Enum.map(specs, &to_filter(&1, opts))}
  def to_filter({:any_of, specs}, opts), do: {:or, Enum.map(specs, &to_filter(&1, opts))}
  def to_filter({:not, spec}, opts), do: {:not, to_filter(spec, opts)}

  def to_filter({module, spec_opts}, opts) when is_atom(module) and is_list(spec_opts),
    do: to_filter(module, Keyword.merge(opts, spec_opts))

  def to_filter(module, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :to_filter, 1),
      do: module.to_filter(opts),
      else:
        raise(
          ArgumentError,
          "#{inspect(module)} cannot be searched with: it defines no to_filter/1"
        )
  end

  @doc "Satisfied only when every spec is satisfied."
  @spec all_of([spec()]) :: spec()
  def all_of(specs) when is_list(specs), do: {:all_of, specs}

  @doc "Satisfied when at least one spec is satisfied."
  @spec any_of([spec()]) :: spec()
  def any_of(specs) when is_list(specs), do: {:any_of, specs}

  @doc "Satisfied when the given spec is not."
  @spec not_spec(spec()) :: spec()
  def not_spec(spec), do: {:not, spec}

  @doc """
  Evaluate a spec against an entity.

  Returns `:ok` or `{:error, violation}` where violation is
  `%{field, code, message, details}`.
  """
  @spec evaluate(spec(), struct(), keyword()) :: :ok | {:error, DDD.Error.violation()}
  def evaluate(spec, entity, opts \\ [])

  def evaluate({:all_of, specs}, entity, opts) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      case evaluate(spec, entity, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def evaluate({:any_of, specs}, entity, opts) do
    Enum.reduce_while(specs, {:error, nil}, fn spec, _ ->
      case evaluate(spec, entity, opts) do
        :ok -> {:halt, :ok}
        {:error, _} = error -> {:cont, error}
      end
    end)
    |> case do
      {:error, nil} ->
        {:error, DDD.Error.violation(:base, :no_spec_satisfied, "no specification given")}

      other ->
        other
    end
  end

  def evaluate({:not, spec}, entity, opts) do
    case evaluate(spec, entity, opts) do
      :ok ->
        {:error,
         DDD.Error.violation(
           :base,
           :negated_spec_satisfied,
           "specification must not be satisfied"
         )}

      {:error, _} ->
        :ok
    end
  end

  def evaluate({module, spec_opts}, entity, opts) when is_atom(module) and is_list(spec_opts),
    do: evaluate(module, entity, Keyword.merge(opts, spec_opts))

  def evaluate(module, entity, opts) when is_atom(module) do
    {field, result} = run_check(module, entity, opts)

    case result do
      :ok ->
        :ok

      {:error, code, message} ->
        {:error, DDD.Error.violation(field, code, message)}

      {:error, code, message, details} ->
        {:error, DDD.Error.violation(field, code, message, details)}
    end
  end

  # A value spec is handed one field's value (never nil: `required: true` covers absence) and
  # reports its failures under that field. An entity spec gets the whole entity.
  defp run_check(module, entity, opts) do
    if module.__spec_scope__() == :value do
      field =
        Keyword.get(opts, :on) ||
          raise ArgumentError,
                "#{inspect(module)} checks a single value: attach it with `on: :field`"

      value =
        case Map.fetch(entity, field) do
          {:ok, value} ->
            value

          :error ->
            raise ArgumentError,
                  "#{inspect(module)}: the entity has no field #{inspect(field)}"
        end

      {field, if(is_nil(value), do: :ok, else: module.check(value, opts))}
    else
      {module.__spec_field__(), module.check(entity, opts)}
    end
  end
end
