defmodule DDD.DescriptionsTest do
  use ExUnit.Case, async: true

  defmodule Thing do
    use DDD.Aggregate

    aggregate do
      description "Something we keep track of"

      identity :id, :uuid
      field :name, :string, required: true, description: "What it is called"
    end

    defop rename(thing, name), description: "Give the thing another name" do
      %{thing | name: name}
    end

    defop plain(thing), do: thing
  end

  defmodule Bare do
    use DDD.ValueObject

    value_object do
      field :x, :integer
    end
  end

  defmodule Order do
    use DDD.Command, transaction: false

    command do
      description "Place an order"
      field :sku, :string, required: true, description: "What to order"
      field :quantity, :integer, default: 1
    end

    def execute(_), do: {:ok, 1}
  end

  test "entities, aggregates and value objects can describe themselves" do
    assert Thing.__ddd_description__() == "Something we keep track of"
    assert Bare.__ddd_description__() == nil
  end

  test "a field's description is kept with the field" do
    {:name, :string, opts} = List.keyfind(Thing.__ddd_fields__(), :name, 0)
    assert opts[:description] == "What it is called"
  end

  test "operations can carry a description; those without don't appear" do
    assert Thing.__ddd_ops__() == [{:rename, 2, "Give the thing another name"}]
  end

  test "a description changes nothing about how the entity works" do
    {:ok, thing} = Thing.new(name: "a")
    assert {:ok, %{name: "b"}} = Thing.rename(thing, "b")
  end

  test "commands and queries declare their description and parameters" do
    assert Order.__description__() == "Place an order"

    assert [{:sku, :string, sku_opts}, {:quantity, :integer, _}] = Order.__params__()
    assert sku_opts[:description] == "What to order"
    assert sku_opts[:required]
  end

  test "command parameters are type-checked and typos fail at compile time" do
    assert {:ok, %{sku: "a", quantity: 1}} = Order.new(sku: "a")
    assert {:error, error} = Order.new(sku: 5, quantity: "many")
    assert Enum.sort(Enum.map(error.violations, & &1.field)) == [:quantity, :sku]

    assert_raise ArgumentError, ~r/unknown field type/, fn ->
      Code.compile_string("""
      defmodule DDD.DescriptionsTest.Typo do
        use DDD.Command
        command do
          field :x, :strng
        end
      end
      """)
    end
  end
end
