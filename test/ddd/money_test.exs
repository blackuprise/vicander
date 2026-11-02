defmodule DDD.MoneyTest do
  use ExUnit.Case, async: true

  alias DDD.{Error, Money}

  defp eur(amount), do: Money.of!(amount, "EUR")

  test "of/2 takes decimals, integers, floats and strings" do
    assert {:ok, %Money{amount: amount, currency: "EUR"}} = Money.of("19.99", "EUR")
    assert Decimal.eq?(amount, "19.99")
    assert Decimal.eq?(eur(5).amount, 5)
    assert Decimal.eq?(eur(0.5).amount, "0.5")
    assert Decimal.eq?(eur(Decimal.new("1.1")).amount, "1.1")
    assert DDD.Schema.sealed?(eur(1))
  end

  test "of/2 rejects garbage amounts and bad currencies" do
    assert {:error, %Error{code: :invalid_amount}} = Money.of("ten", "EUR")
    assert {:error, %Error{code: :invalid_amount}} = Money.of("10x", "EUR")
    assert {:error, %Error{code: :invalid_amount}} = Money.of(:ten, "EUR")
    assert {:error, error} = Money.of(1, "euro")
    assert Error.has_code?(error, :invalid)
    assert {:error, error} = Money.of(1, nil)
    assert Error.has_code?(error, :required)
  end

  test "of!/2 raises on invalid money" do
    assert_raise ArgumentError, ~r/invalid money/, fn -> Money.of!("x", "EUR") end
    assert_raise ArgumentError, ~r/invalid money/, fn -> Money.of!(1, "e") end
  end

  test "arithmetic in one currency" do
    assert {:ok, sum} = Money.add(eur("1.10"), eur("2.20"))
    assert Decimal.eq?(sum.amount, "3.30")
    assert {:ok, diff} = Money.subtract(eur(1), eur(3))
    assert Decimal.eq?(diff.amount, -2)
    assert Money.negative?(diff)
    assert {:ok, tripled} = Money.multiply(eur("2.5"), 3)
    assert Decimal.eq?(tripled.amount, "7.5")
    assert {:error, %Error{code: :invalid_amount}} = Money.multiply(eur(1), "x")
    assert {:ok, rounded} = Money.round(eur("1.005"))
    assert Decimal.eq?(rounded.amount, "1.01")
    assert {:ok, whole} = Money.round(eur("1.5"), 0)
    assert Decimal.eq?(whole.amount, 2)
  end

  test "mixing currencies is a business error" do
    usd = Money.of!(1, "USD")

    assert {:error, %Error{kind: :business, code: :currency_mismatch} = error} =
             Money.add(eur(1), usd)

    assert error.details == %{left: "EUR", right: "USD"}
    assert {:error, %Error{code: :currency_mismatch}} = Money.subtract(eur(1), usd)
    assert {:error, %Error{code: :currency_mismatch}} = Money.compare(eur(1), usd)
  end

  test "comparison and sign" do
    assert {:ok, :lt} = Money.compare(eur(1), eur(2))
    assert {:ok, :eq} = Money.compare(eur("1.0"), eur(1))
    assert {:ok, :gt} = Money.compare(eur(3), eur(2))
    assert Money.positive?(eur(1))
    refute Money.positive?(eur(0))
    assert {:ok, zero} = Money.zero("EUR")
    assert Money.zero?(zero)
    refute Money.zero?(eur(1))
  end

  test "money is a value object: equal when its attributes are" do
    assert Money.equals?(eur(1), eur(1))
    refute Money.equals?(eur(1), eur(2))
  end

  test "an entity can hold money through :money" do
    defmodule Priced do
      use DDD.ValueObject

      value_object do
        field :price, :money, required: true
      end
    end

    assert {:ok, priced} = Priced.new(price: eur(5))
    assert priced.price.currency == "EUR"
    assert {:error, error} = Priced.new(price: "5 EUR")
    assert Error.has_code?(error, :invalid_type)
  end
end
