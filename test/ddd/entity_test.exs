defmodule DDD.EntityTest do
  use ExUnit.Case, async: true

  alias DDD.Error

  defmodule Even do
    use DDD.Specification, field: :quantity

    def check(%{quantity: nil}, _opts), do: :ok

    def check(%{quantity: q}, _opts) do
      if rem(q, 2) == 0, do: :ok, else: {:error, :odd, "must be even", %{quantity: q}}
    end
  end

  # Preconditions: named rules about the entity *before* an operation may run.
  defmodule Open do
    use DDD.Specification, field: :status

    def check(%{status: :open}, _opts), do: :ok

    def check(%{status: status}, _opts),
      do: {:error, :not_open, "must be open", %{status: status}}
  end

  defmodule AtLeast do
    use DDD.Specification, field: :quantity

    def check(%{quantity: quantity}, opts) do
      min = Keyword.fetch!(opts, :min)

      if quantity >= min,
        do: :ok,
        else: {:error, :too_few, "needs at least #{min}", %{min: min, quantity: quantity}}
    end
  end

  # A rule that depends on the operation's argument: the other arguments arrive in opts[:args].
  defmodule Fits do
    use DDD.Specification, field: :quantity

    def check(%{quantity: quantity}, opts) do
      [amount | _] = Keyword.fetch!(opts, :args)
      cap = Keyword.get(opts, :cap, 10)

      if quantity + amount <= cap,
        do: :ok,
        else: {:error, :over_cap, "would exceed #{cap}", %{cap: cap, would_be: quantity + amount}}
    end
  end

  defmodule Recorder do
    use DDD.Specification

    def check(_entity, opts) do
      send(self(), {:spec_args, Keyword.fetch!(opts, :args)})
      :ok
    end
  end

  defmodule Item do
    use DDD.Entity

    entity do
      identity :id, :uuid
      field :sku, :string, required: true
      field :quantity, :integer, default: 2
      field :status, :atom, default: :open

      validate :quantity, &(&1 > 0), message: "must be positive"
      invariant Even
    end

    defop close(%{status: :open} = item), do: %{item | status: :closed}
    defop set_quantity(item, quantity), do: %{item | quantity: quantity}
    defop refuse(_item), do: {:error, {:refused, "not today"}}
    defop refuse_atom(_item), do: {:error, :nope}
    defop wrapped(item), do: {:ok, item}
    defop nonsense(_item), do: :nonsense
    defop positive_only(item, n) when n > 0, do: %{item | quantity: n * 2}
    defop no_args(), do: :unused
    defop absorb(item, other), do: %{item | quantity: item.quantity + other.quantity}

    defop top_up(item, amount), requires: {Fits, cap: 10} do
      %{item | quantity: item.quantity + amount}
    end

    defop top_up_small(item, amount),
      requires: DDD.Specification.all_of([Open, {Fits, cap: 6}]) do
      %{item | quantity: item.quantity + amount}
    end

    defop record_none(item), requires: Recorder do
      item
    end

    defop record_two(item, _a, _b), requires: Recorder do
      item
    end

    defop shelve(item), requires: Open do
      send(self(), :shelve_body_ran)
      %{item | status: :shelved}
    end

    defop clear(item), requires: [Open, {AtLeast, min: 4}] do
      %{item | quantity: 2}
    end

    # Two clauses: the preconditions of every clause apply to the operation.
    defop scale(item, 0), requires: Open do
      item
    end

    defop scale(item, n), requires: {AtLeast, min: 4} do
      %{item | quantity: n * 2}
    end
  end

  defp item!(attrs \\ []) do
    {:ok, item} = Item.new(Keyword.merge([sku: "W-1"], attrs))
    item
  end

  describe "new/1" do
    test "generates a UUID identity, applies defaults and seals the result" do
      assert {:ok, item} = Item.new(sku: "W-1")
      assert String.length(item.id) == 36
      assert item.quantity == 2
      assert item.status == :open
      assert DDD.Schema.sealed?(item)
    end

    test "accepts maps and keeps a given id" do
      id = "6f1f3a52-0b0a-4d6e-9d0b-7a9f3b1d2c11"
      assert {:ok, %{id: ^id}} = Item.new(%{sku: "W-1", id: id})
      assert {:error, error} = Item.new(%{sku: "W-1", id: "fixed"})
      assert Error.has_code?(error, :invalid_type)
    end

    test "reports required fields" do
      assert {:error, %Error{} = error} = Item.new(quantity: 2)
      assert error.entity == Item
      assert error.operation == :new
      assert error.code == :validation_failed
      assert [%{field: :sku, code: :required, message: "is required"}] = error.violations
    end

    test "field rules are skipped for nil values" do
      assert {:ok, _} = Item.new(sku: "W-1", quantity: nil)
    end

    test "reports failed field rules" do
      assert {:error, error} = Item.new(sku: "W-1", quantity: -2)
      assert Error.has_code?(error, :invalid)
      assert Error.to_map(error) == %{quantity: ["must be positive"]}
    end

    test "runs specification invariants with structured reasons" do
      assert {:error, error} = Item.new(sku: "W-1", quantity: 3)

      assert [
               %{field: :quantity, code: :odd, message: "must be even", details: %{quantity: 3}}
             ] = error.violations

      assert Error.codes(error) == [:odd]
    end

    test "specs only run once field rules pass" do
      assert {:error, error} = Item.new(sku: nil, quantity: 3)
      assert Error.codes(error) == [:required]
    end
  end

  describe "update/2" do
    test "applies attrs and re-validates" do
      item = item!()
      assert {:ok, updated} = Item.update(item, quantity: 4)
      assert updated.quantity == 4
      assert DDD.Schema.sealed?(updated)
      assert {:error, error} = Item.update(item, quantity: 3)
      assert error.operation == :update
    end

    test "accepts a function of the current entity" do
      assert {:ok, %{quantity: 6}} = Item.update(item!(), &%{&1 | quantity: 6})
    end

    test "protects identity and ignores unknown keys" do
      item = item!()
      assert {:ok, updated} = Item.update(item, %{id: "other", bogus: 1, sku: "W-2"})
      assert updated.id == item.id
      assert updated.sku == "W-2"
      refute Map.has_key?(updated, :bogus)
    end
  end

  describe "validate/1" do
    test "returns the sealed entity or an error" do
      assert {:ok, _} = Item.validate(item!())
      assert {:error, %{operation: :validate}} = Item.validate(%{item!() | quantity: 3})
    end
  end

  describe "same_identity?/2" do
    test "compares ids only" do
      item = item!()
      {:ok, changed} = Item.update(item, quantity: 4)
      assert Item.same_identity?(item, changed)
      refute Item.same_identity?(item, item!())
    end
  end

  describe "defop" do
    test "validates and seals the returned struct" do
      assert {:ok, %{status: :closed} = closed} = Item.close(item!())
      assert DDD.Schema.sealed?(closed)
    end

    test "takes extra arguments and guards" do
      assert {:ok, %{quantity: 8}} = Item.positive_only(item!(), 4)
      assert {:error, %{code: :invalid_operation}} = Item.positive_only(item!(), -1)
    end

    test "fails validation when the result is invalid" do
      assert {:error, error} = Item.set_quantity(item!(), 3)
      assert error.entity == Item
      assert error.operation == :set_quantity
      assert Error.has_code?(error, :odd)
    end

    test "reports the operation and state when no clause matches" do
      {:ok, closed} = Item.close(item!())
      assert {:error, error} = Item.close(closed)
      assert error.code == :invalid_operation
      assert error.entity == Item
      assert error.operation == :close
      assert error.details == %{state: :closed}
    end

    test "turns {:error, reason} into a DDD.Error tagged with entity and operation" do
      assert {:error,
              %Error{code: :refused, message: "not today", entity: Item, operation: :refuse}} =
               Item.refuse(item!())

      assert {:error, %Error{code: :nope, operation: :refuse_atom}} = Item.refuse_atom(item!())
    end

    test "accepts {:ok, struct}" do
      assert {:ok, _} = Item.wrapped(item!())
    end

    test "raises when the body returns something else" do
      assert_raise ArgumentError, ~r/must return a .*Item struct or \{:error, reason\}/, fn ->
        Item.nonsense(item!())
      end
    end

    test "supports operations without arguments" do
      assert_raise ArgumentError, fn -> Item.no_args() end
    end

    test "does not hide FunctionClauseErrors raised inside the body" do
      defmodule Boom do
        use DDD.Entity

        entity do
          identity :id, :uuid
        end

        defop explode(item), do: helper(item, :bad)

        defp helper(item, :good), do: item
      end

      {:ok, boom} = Boom.new(%{})
      assert_raise FunctionClauseError, fn -> Boom.explode(boom) end
    end
  end

  describe "preconditions (defop requires:)" do
    test "an operation runs when its rules hold" do
      assert {:ok, %{status: :shelved}} = Item.shelve(item!())
      assert_received :shelve_body_ran
    end

    test "a broken rule is a business error that names the rule, and the body never runs" do
      {:ok, closed} = Item.close(item!())

      assert {:error, %Error{} = error} = Item.shelve(closed)

      assert error.kind == :business
      assert error.code == :precondition_failed
      assert error.entity == Item
      assert error.operation == :shelve
      assert error.message == "must be open"
      assert error.details == %{status: :closed}

      assert [
               %{
                 field: :status,
                 code: :not_open,
                 message: "must be open",
                 details: %{status: :closed}
               }
             ] =
               error.violations

      assert Error.has_code?(error, :not_open)
      assert Error.to_map(error) == %{status: ["must be open"]}
      refute_received :shelve_body_ran
    end

    test "every broken rule is reported, not just the first" do
      {:ok, closed} = Item.close(item!(quantity: 2))

      assert {:error, error} = Item.clear(closed)

      assert error.code == :precondition_failed
      assert error.message == "2 preconditions of clear failed"
      assert Error.codes(error) == [:not_open, :too_few]
    end

    test "a rule can take options" do
      assert {:ok, %{quantity: 2}} = Item.clear(item!(quantity: 4))
      assert {:error, error} = Item.clear(item!(quantity: 2))
      assert [%{code: :too_few, details: %{min: 4, quantity: 2}}] = error.violations
    end

    test "the rules of every clause apply to the operation" do
      # scale/2 has two clauses: one requires Open, the other requires a quantity of at least 4.
      # Both rules guard the operation, whichever clause the arguments pick.
      assert {:ok, _} = Item.scale(item!(quantity: 4), 0)
      assert {:ok, %{quantity: 6}} = Item.scale(item!(quantity: 4), 3)

      # Matches the first clause (0), yet the second clause's rule (quantity >= 4) still applies.
      assert {:error, error} = Item.scale(item!(quantity: 2), 0)
      assert Error.codes(error) == [:too_few]

      {:ok, closed} = Item.close(item!(quantity: 4))
      assert {:error, error} = Item.scale(closed, 3)
      assert Error.codes(error) == [:not_open]
    end

    test "a rule can depend on the operation's other arguments" do
      assert {:ok, %{quantity: 8}} = Item.top_up(item!(quantity: 4), 4)

      assert {:error, error} = Item.top_up(item!(quantity: 4), 8)
      assert error.code == :precondition_failed
      assert error.message == "would exceed 10"
      assert [%{code: :over_cap, details: %{cap: 10, would_be: 12}}] = error.violations
    end

    test "the spec gets exactly the arguments after the entity" do
      Item.record_none(item!())
      assert_received {:spec_args, []}

      Item.record_two(item!(), :a, "b")
      assert_received {:spec_args, [:a, "b"]}
    end

    test "composite specs get the arguments too" do
      assert {:ok, _} = Item.top_up_small(item!(quantity: 2), 2)

      # Fits fails (2 + 8 > 6): all_of reports the first failing branch.
      assert {:error, error} = Item.top_up_small(item!(quantity: 2), 8)
      assert Error.codes(error) == [:over_cap]

      {:ok, closed} = Item.close(item!(quantity: 2))
      assert {:error, error} = Item.top_up_small(closed, 2)
      assert Error.codes(error) == [:not_open]
    end

    test "a rejected operation logs the rule, not an exception" do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          {:error, _} = Item.top_up(item!(quantity: 4), 99)
        end)

      assert log =~ "top_up rejected: over_cap"
    end

    test "an unsealed entity is refused before any rule is looked at" do
      tampered = %{item!() | status: :closed}
      assert {:error, %Error{code: :unsealed}} = Item.shelve(tampered)
    end

    test "every framework struct passed as an argument must be sealed, not only the first" do
      good = item!()
      forged = %{item!() | quantity: 99}

      assert {:ok, %{quantity: 4}} = Item.absorb(good, good)

      assert {:error, %Error{code: :unsealed, entity: Item, operation: :absorb} = error} =
               Item.absorb(good, forged)

      assert error.details == %{struct: Item}

      # Plain maps and values are not framework structs: they are the operation's business.
      assert {:ok, %{quantity: 4}} = Item.absorb(good, %{quantity: 2})
    end

    test "operations without requires: keep working, and pattern-matching is still allowed" do
      {:ok, closed} = Item.close(item!())
      assert {:error, %Error{code: :invalid_operation}} = Item.close(closed)
    end
  end

  describe "sealing" do
    test "a struct literal does not compile" do
      assert_raise ArgumentError, ~r/__sealed__/, fn ->
        Code.eval_string("%DDD.EntityTest.Item{sku: \"x\"}")
      end
    end

    test "a tampered struct is no longer sealed and is refused by defop" do
      tampered = %{item!() | quantity: 3}
      refute DDD.Schema.sealed?(tampered)

      assert {:error, %Error{code: :unsealed, operation: :close}} = Item.close(tampered)
    end

    test "a forged seal does not pass" do
      forged = struct(Item, sku: "x", __sealed__: true)
      refute DDD.Schema.sealed?(forged)
    end

    test "non-structs are never sealed" do
      refute DDD.Schema.sealed?(%{})
    end
  end

  describe "created_at / updated_at" do
    test "new sets both to the same instant" do
      item = item!()
      assert %DateTime{} = item.created_at
      assert item.created_at == item.updated_at
    end

    test "update and defop bump updated_at and keep created_at" do
      item = item!()
      Process.sleep(2)
      {:ok, updated} = Item.update(item, quantity: 4)
      assert updated.created_at == item.created_at
      assert DateTime.compare(updated.updated_at, item.updated_at) == :gt

      Process.sleep(2)
      {:ok, closed} = Item.close(updated)
      assert closed.created_at == item.created_at
      assert DateTime.compare(closed.updated_at, updated.updated_at) == :gt
    end

    test "validate/1 changes nothing, so it does not bump updated_at" do
      item = item!()
      Process.sleep(2)
      assert {:ok, ^item} = Item.validate(item)
    end

    test "update cannot override the managed timestamps" do
      item = item!()
      forged = ~U[2000-01-01 00:00:00.000000Z]
      {:ok, updated} = Item.update(item, created_at: forged, updated_at: forged, quantity: 4)
      assert updated.created_at == item.created_at
      refute updated.updated_at == forged
    end

    test "a failed operation does not touch the entity" do
      item = item!()
      assert {:error, _} = Item.set_quantity(item, 3)
      assert item.updated_at == item.created_at
    end

    test "an explicit created_at is kept on new, and declaring the fields yourself is allowed" do
      created = ~U[2020-05-01 10:00:00.000000Z]
      assert {:ok, %{created_at: ^created}} = Item.new(sku: "x", created_at: created)

      defmodule OwnTimestamps do
        use DDD.Entity

        entity do
          identity :id, :uuid
          field :created_at, :datetime_usec
        end
      end

      names = Enum.map(OwnTimestamps.__ddd_fields__(), &elem(&1, 0))
      assert names == [:id, :created_at, :updated_at]
    end
  end

  test "introspection" do
    assert Item.__ddd_kind__() == :entity
    assert [{:id, :uuid, []}] = Item.__ddd_identity__()
    assert Item.identity_fields() == [:id]

    assert [:id, :sku, :quantity, :status, :created_at, :updated_at] =
             Enum.map(Item.__ddd_fields__(), &elem(&1, 0))
  end
end
