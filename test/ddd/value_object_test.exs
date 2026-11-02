defmodule DDD.ValueObjectTest do
  use ExUnit.Case, async: true

  defmodule Money do
    use DDD.ValueObject

    value_object do
      field :amount, :decimal, required: true
      field :currency, :string, required: true

      validate :currency, &(String.length(&1) == 3), message: "must be 3-letter ISO code"
    end

    def add(%__MODULE__{currency: c} = a, %__MODULE__{currency: c} = b),
      do: new(amount: Decimal.add(a.amount, b.amount), currency: c)

    def add(_, _), do: {:error, :currency_mismatch}
  end

  describe "new/1" do
    test "creates a sealed value object" do
      assert {:ok, money} = Money.new(amount: Decimal.new("10.00"), currency: "USD")
      assert money.amount == Decimal.new("10.00")
      assert DDD.Schema.sealed?(money)
    end

    test "accepts map attrs" do
      assert {:ok, _} = Money.new(%{amount: Decimal.new("5.00"), currency: "EUR"})
    end

    test "returns a DDD.Error for invalid attributes" do
      assert {:error, error} = Money.new(amount: Decimal.new("10"), currency: "US")
      assert error.entity == Money
      assert DDD.Error.to_map(error) == %{currency: ["must be 3-letter ISO code"]}
    end

    test "missing required fields are reported, and a nil rule input does not crash" do
      assert {:error, error} = Money.new(currency: nil)
      assert DDD.Error.codes(error) == [:required, :required]
    end
  end

  describe "equals?/2" do
    test "compares by value" do
      {:ok, a} = Money.new(amount: Decimal.new("10.00"), currency: "USD")
      {:ok, b} = Money.new(amount: Decimal.new("10.00"), currency: "USD")
      {:ok, c} = Money.new(amount: Decimal.new("20.00"), currency: "USD")
      assert Money.equals?(a, b)
      refute Money.equals?(a, c)
    end
  end

  describe "custom domain method" do
    test "add/2 builds the result through new/1" do
      {:ok, a} = Money.new(amount: Decimal.new("10.00"), currency: "USD")
      {:ok, b} = Money.new(amount: Decimal.new("5.00"), currency: "USD")
      {:ok, d} = Money.new(amount: Decimal.new("5.00"), currency: "EUR")
      assert {:ok, sum} = Money.add(a, b)
      assert sum.amount == Decimal.new("15.00")
      assert {:error, :currency_mismatch} = Money.add(a, d)
    end
  end

  test "value objects have no timestamps: they are immutable" do
    {:ok, money} = Money.new(amount: Decimal.new("1"), currency: "USD")
    refute Map.has_key?(money, :created_at)
    refute Map.has_key?(money, :updated_at)
  end

  test "has no update/2: value objects are immutable" do
    refute function_exported?(Money, :update, 2)
  end
end
