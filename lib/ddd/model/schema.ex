defmodule DDD.Schema do
  @moduledoc false
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # (`__before_compile__` is the macro that generates an entity; it is long because the entity is)
  # Shared core behind DDD.Entity, DDD.Aggregate and DDD.ValueObject.
  #
  # Handles fields, defaults, identity, field rules, specification invariants,
  # `defop` business operations and sealing.
  #
  # Sealing: every struct has a required `__sealed__` key, so a struct literal
  # (`%Todo{...}`) does not compile by accident. The seal is a fingerprint of the
  # struct's data, set only after validation succeeds. A forged or tampered struct
  # fails `sealed?/1`, and repositories and `defop` reject it.

  require Logger

  alias DDD.Error

  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)
    behaviour = Keyword.fetch!(opts, :behaviour)

    quote do
      import DDD.Schema,
        only: [
          field: 2,
          field: 3,
          identity: 2,
          identity: 3,
          validate: 2,
          validate: 3,
          invariant: 1,
          invariant: 2,
          description: 1,
          defop: 2,
          defop: 3
        ]

      @behaviour unquote(behaviour)
      Module.register_attribute(__MODULE__, :ddd_ops, accumulate: true)
      Module.register_attribute(__MODULE__, :ddd_op_docs, accumulate: true)
      Module.register_attribute(__MODULE__, :ddd_op_args, accumulate: true)
      @ddd_description nil
      @ddd_kind unquote(kind)
      @ddd_behaviour unquote(behaviour)
      @ddd_fields []
      @ddd_validations []
      @ddd_invariants []
      @ddd_identity []
      @before_compile DDD.Schema
    end
  end

  @doc false
  defmacro define_struct(block) do
    quote do
      unquote(block)
      @enforce_keys [:__sealed__]
      @ddd_fields DDD.Schema.with_version(
                    @ddd_kind,
                    DDD.Schema.with_timestamps(@ddd_kind, @ddd_fields)
                  )
      defstruct DDD.Schema.struct_fields(@ddd_kind, @ddd_fields)
    end
  end

  # Entities and aggregates get framework-managed `created_at` / `updated_at` fields
  # (value objects are immutable, so they get none). `@ddd_fields` is stored reversed,
  # so prepending puts them last.
  @doc false
  def with_timestamps(kind, fields) when kind in [:entity, :aggregate] do
    declared = Enum.map(fields, fn {name, _type, _opts} -> name end)

    new =
      for name <- [:created_at, :updated_at], name not in declared do
        {name, :datetime_usec, []}
      end

    Enum.reverse(new) ++ fields
  end

  def with_timestamps(_kind, fields), do: fields

  # Aggregates carry a `version` for optimistic locking. It starts at 0 and is advanced by the
  # repository on every save, never by the domain. A `version` the aggregate declares itself
  # is left alone.
  @doc false
  def with_version(:aggregate, fields) do
    if Enum.any?(fields, fn {name, _type, _opts} -> name == :version end),
      do: fields,
      else: [{:version, :integer, [default: 0]} | fields]
  end

  def with_version(_kind, fields), do: fields

  @doc false
  def struct_fields(kind, fields) do
    base = [__sealed__: nil] ++ if(kind == :aggregate, do: [__pending_events__: []], else: [])

    base ++
      (fields
       |> Enum.reverse()
       |> Enum.map(fn {name, _type, opts} -> {name, Keyword.get(opts, :default)} end))
  end

  defmacro identity(name, type, opts \\ []) do
    quote do
      @ddd_identity [
        {unquote(name), DDD.Type.normalize!(unquote(type)), unquote(opts)} | @ddd_identity
      ]
      @ddd_fields [
        {unquote(name), DDD.Type.normalize!(unquote(type)), unquote(opts)} | @ddd_fields
      ]
    end
  end

  defmacro field(name, type, opts \\ []) do
    quote do
      @ddd_fields [
        {unquote(name), DDD.Type.normalize!(unquote(type)), unquote(opts)} | @ddd_fields
      ]
    end
  end

  # Validators are stored as quoted AST (closures cannot live in module
  # attributes that get injected into function bodies) and re-injected in
  # __before_compile__.
  defmacro validate(field, validator, opts \\ []) do
    quote do
      @ddd_validations [
        {unquote(field), unquote(Macro.escape(validator)), unquote(opts)} | @ddd_validations
      ]
    end
  end

  @doc """
  Describe the entity, aggregate or value object in a sentence. Any tool that explains the model
  (the MCP server, documentation) reads it back with `__ddd_description__/0`.
  """
  defmacro description(text) do
    quote do
      @ddd_description unquote(text)
    end
  end

  defmacro invariant(spec, opts \\ []) do
    quote do
      @ddd_invariants [{unquote(spec), unquote(opts)} | @ddd_invariants]
    end
  end

  @doc """
  Defines a business operation. The body returns the new struct (or
  `{:error, reason}`); the framework validates and seals the result.

  `requires:` lists the specifications the entity (the first argument) must satisfy *before*
  the operation may run. They are the operation's business rules, stated by name:

      defop complete(item), requires: MyApp.Specs.ItemNotCompleted do
        %{item | status: :done}
      end

  The operation's other arguments are given to every spec as `opts[:args]`, so a rule can
  depend on them:

      defop complete_item(list, item_id), requires: MyApp.Specs.ItemExists do
        ...
      end

      # in the spec:  def check(list, opts), do: [item_id] = Keyword.fetch!(opts, :args) ...

  A broken precondition returns a business error (`code: :precondition_failed`) whose
  violations carry each rule's own code and message. The body never runs.
  """
  defmacro defop(call, do: body), do: define_op(call, [], body, __CALLER__)
  defmacro defop(call, opts, do: body), do: define_op(call, opts, body, __CALLER__)

  defp define_op(call, opts, body, caller) do
    {call, guard} =
      case call do
        {:when, _, [call, guard]} -> {call, guard}
        call -> {call, true}
      end

    {name, _, args} = call
    args = args || []
    impl = impl_name(name)
    requires = Keyword.get(opts, :requires, [])
    description = Keyword.get(opts, :description)

    quote do
      @ddd_ops {unquote(name), unquote(length(args)), List.wrap(unquote(requires))}
      @ddd_op_args {unquote(name), unquote(length(args)), unquote(arg_names(args)),
                    unquote(caller.line)}

      if unquote(description) do
        @ddd_op_docs {unquote(name), unquote(length(args)), unquote(description)}
      end

      defp unquote(impl)(unquote_splicing(args)) when unquote(guard) do
        unquote(body)
      end
    end
  end

  @doc false
  def impl_name(name), do: :"__op_#{name}__"

  # Readable parameter names for an operation's signature (see `__ddd_op_signatures__/0`): the
  # variable of a plain or `pattern = var` argument, else `argN`.
  defp arg_names(args) do
    args
    |> Enum.with_index(1)
    |> Enum.map(fn {arg, index} -> arg_name(arg) || "arg#{index}" end)
  end

  defp arg_name({name, _, context}) when is_atom(name) and is_atom(context) do
    case Atom.to_string(name) do
      "_" -> nil
      "_" <> rest -> rest
      name -> name
    end
  end

  defp arg_name({:=, _, [left, right]}), do: arg_name(right) || arg_name(left)
  defp arg_name(_), do: nil

  defmacro __before_compile__(env) do
    module = env.module
    kind = Module.get_attribute(module, :ddd_kind)
    behaviour = Module.get_attribute(module, :ddd_behaviour)
    fields = Module.get_attribute(module, :ddd_fields)

    rules =
      module
      |> Module.get_attribute(:ddd_validations)
      |> Enum.reverse()
      |> Enum.map(fn {field, validator_ast, opts} ->
        quote do: {unquote(field), unquote(validator_ast), unquote(opts)}
      end)

    identity_parts = module |> Module.get_attribute(:ddd_identity) |> Enum.reverse()
    identity_names = Enum.map(identity_parts, &elem(&1, 0))
    check_identity!(env, identity_parts)

    # Every identity part is required, declared so or not.
    required =
      (for({name, _type, opts} <- fields, Keyword.get(opts, :required, false), do: name) ++
         identity_names)
      |> Enum.uniq()

    field_names = Enum.map(fields, fn {name, _, _} -> name end)
    types = for {name, type, _opts} <- fields, do: {name, type}
    check_invariant_fields!(env, Module.get_attribute(module, :ddd_invariants), field_names)

    # One entry per `defop` clause: {name, arity, requires}. An operation with several clauses
    # is checked against the preconditions of all of them.
    clauses = module |> Module.get_attribute(:ddd_ops) |> Enum.reverse()
    ops = clauses |> Enum.map(fn {name, arity, _requires} -> {name, arity} end) |> Enum.uniq()

    descriptions =
      for {name, arity, text} <- Module.get_attribute(module, :ddd_op_docs),
          into: %{},
          do: {{name, arity}, text}

    arg_names =
      module
      |> Module.get_attribute(:ddd_op_args)
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn {name, arity, names, line}, acc ->
        Map.put_new(acc, {name, arity}, {names, line})
      end)

    op_signatures =
      for {name, arity} <- ops do
        {names, line} = Map.fetch!(arg_names, {name, arity})

        %{
          name: name,
          arity: arity,
          args: names,
          line: line,
          requires: for({^name, ^arity, specs} <- clauses, spec <- specs, uniq: true, do: spec),
          description: Map.get(descriptions, {name, arity})
        }
      end

    op_wrappers =
      for {name, arity} <- ops do
        args = Macro.generate_arguments(arity, module)
        impl = impl_name(name)

        requires =
          for {^name, ^arity, specs} <- clauses, spec <- specs, uniq: true, do: spec

        quote do
          def unquote(name)(unquote_splicing(args)) do
            DDD.Schema.run_op(
              __MODULE__,
              unquote(name),
              unquote(args),
              unquote(Macro.escape(requires)),
              fn -> unquote(impl)(unquote_splicing(args)) end
            )
          end
        end
      end

    common =
      quote do
        @doc false
        def __ddd_fields__, do: Enum.reverse(@ddd_fields)
        @doc false
        def __ddd_identity__, do: Enum.reverse(@ddd_identity)
        @doc false
        def __ddd_kind__, do: @ddd_kind
        @doc false
        def __ddd_description__, do: @ddd_description
        @doc false
        # The operations that carry a description: [{name, arity, description}].
        def __ddd_ops__, do: Enum.reverse(@ddd_op_docs)

        @doc false
        # Every operation: %{name, arity, args, line, requires, description}.
        def __ddd_op_signatures__, do: unquote(Macro.escape(op_signatures))

        @doc """
        Run field rules, then specification invariants. Returns the sealed
        struct or a `DDD.Error` listing every violation.
        """
        def validate(struct) do
          # Events come only from `emit_event/2`, which keeps the seal. A struct that carries
          # events but is no longer sealed had them put there (or its data changed) by hand, and
          # validating it would seal them.
          with :ok <- DDD.Schema.check_events_sealed(struct, __MODULE__) do
            __ddd_validate__(struct, :validate)
          end
        end

        @doc false
        def __ddd_validate__(struct, operation) do
          DDD.Schema.run_validation(
            __MODULE__,
            struct,
            operation,
            unquote(required),
            unquote(Macro.escape(types)),
            unquote(rules),
            Enum.reverse(@ddd_invariants)
          )
        end

        @impl unquote(behaviour)
        def new(attrs) when is_map(attrs) or is_list(attrs) do
          # The seal and the pending events belong to the framework; callers can't supply them.
          attrs = attrs |> Map.new() |> Map.drop([:__sealed__, :__pending_events__])

          # A new aggregate starts at version 0; only the repository advances it.
          attrs = if unquote(kind == :aggregate), do: Map.drop(attrs, [:version]), else: attrs

          # Only a lone `identity(:id, :uuid)` is generated (a UUIDv7). Any other identity is
          # passed by the caller.
          attrs = DDD.Identity.put_generated(attrs, @ddd_identity)

          __MODULE__ |> struct(attrs) |> __ddd_validate__(:new)
        end

        defoverridable new: 1
      end

    identity_q =
      if kind in [:entity, :aggregate] do
        quote do
          @doc "The names of the fields that make up the identity."
          def identity_fields, do: unquote(identity_names)

          @doc """
          The identity as a string: the value of a single identity field, or the values joined
          with `:` (a `:` or `\\` inside a value is escaped).
          """
          def identity(%__MODULE__{} = entity), do: DDD.Identity.build(__MODULE__, entity)

          @doc """
          The identity string made from a map or keyword list of the identity parts, without an
          entity. Raises when a part is missing.
          """
          def build_identity(parts) when is_map(parts) or is_list(parts),
            do: DDD.Identity.build(__MODULE__, parts)
        end
      end

    update_q =
      if kind in [:entity, :aggregate] do
        quote do
          @impl unquote(behaviour)
          def update(entity, changes) when is_function(changes, 1) do
            with :ok <- DDD.Schema.require_sealed(entity, __MODULE__, :update) do
              entity
              |> changes.()
              |> __ddd_validate__(:update)
              |> DDD.Schema.keep_identity(__MODULE__, :update, entity)
            end
          end

          def update(entity, attrs) when is_map(attrs) or is_list(attrs) do
            with :ok <- DDD.Schema.require_sealed(entity, __MODULE__, :update) do
              attrs = attrs |> Map.new() |> Map.take(unquote(field_names))

              # Identity and timestamps are managed by the framework.
              attrs = Map.drop(attrs, [:created_at, :updated_at])

              # The version is advanced by the repository on save.
              attrs = if unquote(kind == :aggregate), do: Map.drop(attrs, [:version]), else: attrs

              attrs = Map.drop(attrs, unquote(identity_names))

              entity |> Map.merge(attrs) |> __ddd_validate__(:update)
            end
          end

          defoverridable update: 2
        end
      end

    entity_q =
      if kind == :entity do
        quote do
          @impl unquote(behaviour)
          def same_identity?(a, b) do
            DDD.Identity.key(a) == DDD.Identity.key(b)
          end

          defoverridable same_identity?: 2
        end
      end

    aggregate_q =
      if kind == :aggregate do
        quote do
          @doc """
          Append a domain event to the aggregate's pending event list.

          The event is linked to this aggregate: `aggregate_type` (module name as a
          string) and `aggregate_id` are filled in.
          """
          def emit_event(aggregate, event) do
            event = DDD.Schema.link_event(event, __MODULE__, identity(aggregate))
            DDD.Schema.with_events(aggregate, aggregate.__pending_events__ ++ [event])
          end

          @doc "Pop and clear all pending domain events. Does not affect the seal."
          def pop_events(aggregate) do
            {aggregate.__pending_events__, DDD.Schema.with_events(aggregate, [])}
          end
        end
      end

    value_object_q =
      if kind == :value_object do
        quote do
          @impl unquote(behaviour)
          def equals?(a, b) do
            Map.drop(a, [:__sealed__]) == Map.drop(b, [:__sealed__])
          end

          defoverridable equals?: 2
        end
      end

    quote do
      unquote(common)
      unquote(identity_q)
      unquote(update_q)
      unquote(entity_q)
      unquote(aggregate_q)
      unquote(value_object_q)
      (unquote_splicing(op_wrappers))
    end
  end

  # A composite identity is stored as one string, so its parts must be types with a plain,
  # unambiguous text form.
  defp check_identity!(env, parts) when length(parts) > 1 do
    for {name, type, _opts} <- parts, not DDD.Identity.composite_type?(type) do
      compile_error!(
        env,
        "identity part #{inspect(name)} has type #{inspect(type)}: a part of a composite " <>
          "identity must be a string, uuid, integer, atom, date or enum"
      )
    end

    :ok
  end

  defp check_identity!(_env, _parts), do: :ok

  # An operation or update must not change which entity it is: the identity string before and
  # after has to be the same.
  @doc false
  def keep_identity({:ok, %{__struct__: module} = new}, module, op, %{__struct__: module} = old) do
    if DDD.Identity.key(old) == DDD.Identity.key(new) do
      {:ok, new}
    else
      {:error,
       Error.business(
         entity: module,
         entity_id: DDD.Identity.id_of(old),
         operation: op,
         code: :identity_changed,
         message: "#{op} must not change the identity of #{inspect(module)}"
       )}
    end
  end

  def keep_identity(result, _module, _op, _old), do: result

  # A value spec is attached to a field with `on:`. A missing `on:` or a field the entity
  # doesn't have (a typo, or a rename that missed this line) is a compile error, not a spec
  # that quietly checks nothing.
  defp check_invariant_fields!(env, invariants, field_names) do
    for {spec, opts} <- invariants, {module, spec_opts} <- leaf_specs(spec, opts) do
      with {:module, _} <- Code.ensure_compiled(module),
           true <- function_exported?(module, :__spec_scope__, 0),
           :value <- module.__spec_scope__() do
        check_on_field!(env, module, Keyword.get(spec_opts, :on), field_names)
      end
    end

    :ok
  end

  defp check_on_field!(env, module, nil, _field_names),
    do: compile_error!(env, "#{inspect(module)} checks a single value: add `on: :field`")

  defp check_on_field!(env, module, field, field_names) do
    if field not in field_names do
      compile_error!(
        env,
        "#{inspect(module)} is attached `on: #{inspect(field)}`, but " <>
          "#{inspect(env.module)} has no such field (fields: #{inspect(field_names)})"
      )
    end
  end

  defp leaf_specs({:all_of, specs}, opts), do: Enum.flat_map(specs, &leaf_specs(&1, opts))
  defp leaf_specs({:any_of, specs}, opts), do: Enum.flat_map(specs, &leaf_specs(&1, opts))
  defp leaf_specs({:not, spec}, opts), do: leaf_specs(spec, opts)

  defp leaf_specs({module, own}, opts) when is_atom(module) and is_list(own),
    do: [{module, Keyword.merge(opts, own)}]

  defp leaf_specs(module, opts) when is_atom(module), do: [{module, opts}]

  defp compile_error!(env, description),
    do: raise(CompileError, file: env.file, line: env.line, description: description)

  # ── Validation ────────────────────────────────────────────────────────────

  @doc false
  def run_validation(module, struct, operation, required, types, rules, invariants) do
    type_violations =
      for {field, type} <- types,
          value <- [Map.get(struct, field)],
          not is_nil(value),
          not DDD.Type.valid?(type, value) do
        Error.violation(
          field,
          :invalid_type,
          "must be #{DDD.Type.describe(type)}",
          %{type: type}
        )
      end

    # A rule assumes a value of the right type, so it is skipped for fields that are mistyped.
    mistyped = Enum.map(type_violations, & &1.field)

    field_violations =
      Enum.flat_map(required, fn field ->
        if is_nil(Map.get(struct, field)),
          do: [Error.violation(field, :required, "is required")],
          else: []
      end) ++
        type_violations ++
        Enum.flat_map(rules, fn {field, validator, opts} ->
          value = Map.get(struct, field)

          if is_nil(value) or field in mistyped or validator.(value),
            do: [],
            else: [Error.violation(field, :invalid, Keyword.get(opts, :message, "is invalid"))]
        end)

    # Specs assume a well-formed entity, so they only run once field rules pass.
    violations =
      if field_violations == [] do
        Enum.flat_map(invariants, fn {spec, opts} ->
          case DDD.Specification.evaluate(spec, struct, opts) do
            :ok -> []
            {:error, violation} -> [violation]
          end
        end)
      else
        field_violations
      end

    case violations do
      [] ->
        {:ok, struct |> stamp(operation) |> seal()}

      _ ->
        {:error,
         Error.validation_failed(module, operation, violations, DDD.Identity.id_of(struct))}
    end
  end

  # `new` sets both timestamps, any other change bumps `updated_at`, and a plain
  # `validate/1` changes nothing. Structs without the fields (value objects) are untouched.
  #
  # An aggregate is different: its `updated_at` says when it was last *stored*, so an operation
  # leaves it alone and the repository sets it when it writes the aggregate (`touch/1`). An
  # operation that changes nothing stored then leaves the aggregate as it was.
  defp stamp(%{created_at: _, updated_at: _, __pending_events__: _} = struct, operation) do
    case operation do
      :new ->
        now = DateTime.utc_now()
        %{struct | created_at: struct.created_at || now, updated_at: struct.updated_at || now}

      _ ->
        struct
    end
  end

  defp stamp(%{created_at: _, updated_at: _} = struct, operation) do
    now = DateTime.utc_now()

    case operation do
      :new ->
        %{struct | created_at: struct.created_at || now, updated_at: struct.updated_at || now}

      :validate ->
        struct

      _ ->
        %{struct | updated_at: now}
    end
  end

  defp stamp(struct, _operation), do: struct

  # ── Operations ────────────────────────────────────────────────────────────

  @doc false
  def run_op(module, op, args, requires, thunk) do
    with :ok <- check_sealed(module, op, args),
         :ok <- check_requires(module, op, args, requires) do
      result =
        thunk
        |> call_op(module, op, args)
        |> finish_op(module, op)
        |> keep_identity(module, op, List.first(args))

      log_op(module, op, result)
      result
    else
      {:error, _} = error ->
        log_op(module, op, error)
        error
    end
  end

  # Preconditions: named specifications the entity must satisfy before the operation runs.
  # They apply to the first argument (the entity); the other arguments reach each spec as
  # `opts[:args]`, so a rule can depend on them. Every broken rule is reported, none stops
  # the others.
  defp check_requires(_module, _op, _args, []), do: :ok

  defp check_requires(module, op, [first | rest], requires) when is_struct(first, module) do
    violations =
      for spec <- requires,
          {:error, violation} <- [DDD.Specification.evaluate(spec, first, args: rest)],
          do: violation

    case violations do
      [] ->
        :ok

      violations ->
        {:error, precondition_error(module, op, violations, DDD.Identity.id_of(first))}
    end
  end

  defp check_requires(_module, _op, _args, _requires), do: :ok

  defp precondition_error(module, op, [violation], entity_id) do
    Error.business(
      entity: module,
      entity_id: entity_id,
      operation: op,
      code: :precondition_failed,
      message: violation.message,
      details: violation.details,
      violations: [violation]
    )
  end

  defp precondition_error(module, op, violations, entity_id) do
    Error.business(
      entity: module,
      entity_id: entity_id,
      operation: op,
      code: :precondition_failed,
      message: "#{length(violations)} preconditions of #{op} failed",
      violations: violations
    )
  end

  defp log_op(module, op, {:ok, _}), do: Logger.debug("[op] #{inspect(module)}.#{op} ok")

  defp log_op(module, op, {:error, %Error{} = error}) do
    Logger.debug(
      "[op] #{inspect(module)}.#{op} rejected: #{error |> Error.codes() |> Enum.join(", ")}"
    )
  end

  # Every DDD struct handed to an operation, the entity and any other argument alike, must have
  # been produced by the framework. A hand-made or tampered one is refused before anything runs.
  defp check_sealed(module, op, args) do
    case Enum.find(args, &(framework_struct?(&1) and not sealed?(&1))) do
      nil ->
        :ok

      %{__struct__: struct_module} ->
        {:error,
         Error.new(
           entity: module,
           entity_id: args |> List.first() |> DDD.Identity.id_of(),
           operation: op,
           code: :unsealed,
           message:
             "#{inspect(struct_module)} was not produced (or was modified outside) by the framework",
           details: %{struct: struct_module}
         )}
    end
  end

  @doc false
  # `update/2` starts from an entity the framework produced: a hand-made or tampered one is
  # refused, as `defop` and the repositories refuse it.
  def require_sealed(entity, module, operation) do
    if sealed?(entity) do
      :ok
    else
      {:error,
       Error.new(
         entity: module,
         entity_id: DDD.Identity.id_of(entity),
         operation: operation,
         code: :unsealed,
         message:
           "#{inspect(module)} was not produced (or was modified outside) by the framework",
         details: %{struct: module}
       )}
    end
  end

  defp framework_struct?(%{__struct__: _, __sealed__: _}), do: true
  defp framework_struct?(_), do: false

  defp call_op(thunk, module, op, args) do
    impl = impl_name(op)

    try do
      thunk.()
    rescue
      e in FunctionClauseError ->
        if e.module == module and e.function == impl do
          {:error,
           Error.new(
             entity: module,
             entity_id: args |> List.first() |> DDD.Identity.id_of(),
             operation: op,
             code: :invalid_operation,
             message: "operation #{op} is not allowed in the current state",
             details: %{state: state_of(args)}
           )}
        else
          reraise e, __STACKTRACE__
        end
    end
  end

  defp state_of([first | _]) when is_map(first), do: Map.get(first, :status)
  defp state_of(_), do: nil

  defp finish_op({:ok, %{__struct__: module} = struct}, module, op),
    do: finish_op(struct, module, op)

  defp finish_op(%{__struct__: module} = struct, module, op),
    do: module.__ddd_validate__(struct, op)

  defp finish_op({:error, reason}, module, op) do
    error = Error.wrap(reason, %{})
    {:error, %{error | entity: error.entity || module, operation: error.operation || op}}
  end

  defp finish_op(other, module, op) do
    raise ArgumentError,
          "#{inspect(module)}.#{op} must return a #{inspect(module)} struct or {:error, reason}, " <>
            "got: #{inspect(other)}"
  end

  @doc false
  def link_event(%{aggregate_type: _, aggregate_id: _} = event, module, id) do
    %{
      event
      | aggregate_type: module |> Module.split() |> Enum.join("."),
        aggregate_id: to_string(id)
    }
  end

  def link_event(event, _module, _id), do: event

  # ── Sealing ───────────────────────────────────────────────────────────────

  @doc false
  # Set `updated_at` to now, for an aggregate that is about to be stored. Not sealed: the
  # caller seals once it has finished changing the struct.
  def touch(%{updated_at: _} = aggregate), do: %{aggregate | updated_at: DateTime.utc_now()}
  def touch(aggregate), do: aggregate

  @doc "Seal a struct (stamp it with a fingerprint of its data)."
  def seal(%{__struct__: _} = struct), do: %{struct | __sealed__: fingerprint(struct)}

  @doc "True when the struct carries a seal matching its current data."
  def sealed?(%{__sealed__: seal} = struct) when is_integer(seal), do: seal == fingerprint(struct)
  def sealed?(_), do: false

  # The pending events are part of what is sealed: they can only change through `emit_event/2`
  # and `pop_events/1`, which re-seal. Replacing the list by hand breaks the seal.
  defp fingerprint(struct),
    do: :erlang.phash2(Map.delete(struct, :__sealed__), 4_294_967_296)

  @doc false
  def check_events_sealed(%{__pending_events__: [_ | _]} = struct, module) do
    require_sealed(struct, module, :validate)
  end

  def check_events_sealed(_struct, _module), do: :ok

  @doc false
  # Replace the pending events of an aggregate. A sealed aggregate stays sealed (the events are
  # covered by the seal); one that is not sealed (an operation is still building it) is left
  # unsealed, so the seal is never handed to a struct that was not validated.
  def with_events(aggregate, events) do
    updated = %{aggregate | __pending_events__: events}
    if sealed?(aggregate), do: seal(updated), else: updated
  end

  @doc "Error returned by repositories when handed a struct that is not sealed."
  def unsealed_error(%{__struct__: module} = struct) do
    Error.new(
      entity: module,
      entity_id: DDD.Identity.id_of(struct),
      operation: :save,
      code: :unsealed,
      message: "#{inspect(module)} was not produced (or was modified outside) by the framework"
    )
  end
end
