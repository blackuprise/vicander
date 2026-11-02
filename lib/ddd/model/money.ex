defmodule DDD.Money do
  @moduledoc """
  An amount of money in one currency, as a value object.

      field :price, :money                 # shorthand for {:one, DDD.Money}

      {:ok, price} = DDD.Money.of("19.99", "EUR")
      {:ok, total} = DDD.Money.add(price, price)
      {:ok, half}  = DDD.Money.multiply(price, "0.5")

  The amount is a `Decimal`, never a float. The currency is a 3-letter ISO 4217 code.
  Adding or subtracting two currencies is a business error (`:currency_mismatch`); there is no
  silent conversion. Money is stored as `jsonb` (`{"amount": "19.99", "currency": "EUR"}`).
  """
  use DDD.ValueObject

  alias DDD.Error

  value_object do
    field(:amount, :decimal, required: true)
    field(:currency, :string, required: true)

    validate(:currency, &Regex.match?(~r/\A[A-Z]{3}\z/, &1), message: "must be a 3-letter code")
  end

  @doc "Build money from an amount (`Decimal`, integer, float or string) and a currency."
  @spec of(Decimal.t() | integer() | float() | String.t(), String.t()) ::
          {:ok, struct()} | {:error, Error.t()}
  def of(amount, currency) do
    case to_decimal(amount) do
      {:ok, decimal} -> new(amount: decimal, currency: currency)
      :error -> invalid_amount(amount)
    end
  end

  @doc "Like `of/2` but returns the money or raises."
  def of!(amount, currency) do
    case of(amount, currency) do
      {:ok, money} -> money
      {:error, error} -> raise ArgumentError, "invalid money: #{error.message}"
    end
  end

  @doc "Zero in `currency`."
  def zero(currency), do: of(0, currency)

  @doc """
  Sum of two amounts in the same currency.

      iex> {:ok, sum} = DDD.Money.add(DDD.Money.of!("1.10", "EUR"), DDD.Money.of!("2.20", "EUR"))
      iex> Decimal.to_string(sum.amount)
      "3.30"
      iex> {:error, error} = DDD.Money.add(DDD.Money.of!(1, "EUR"), DDD.Money.of!(1, "USD"))
      iex> error.code
      :currency_mismatch
  """
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    with :ok <- same_currency(a, b),
         do: new(amount: Decimal.add(a.amount, b.amount), currency: a.currency)
  end

  @doc "Difference of two amounts in the same currency (may be negative)."
  def subtract(%__MODULE__{} = a, %__MODULE__{} = b) do
    with :ok <- same_currency(a, b),
         do: new(amount: Decimal.sub(a.amount, b.amount), currency: a.currency)
  end

  @doc "Multiply by a number (`Decimal`, integer, float or string)."
  def multiply(%__MODULE__{} = money, factor) do
    case to_decimal(factor) do
      {:ok, f} -> new(amount: Decimal.mult(money.amount, f), currency: money.currency)
      :error -> invalid_amount(factor)
    end
  end

  @doc "Round to `places` decimal places (default 2), half up."
  def round(%__MODULE__{} = money, places \\ 2),
    do: new(amount: Decimal.round(money.amount, places, :half_up), currency: money.currency)

  @doc "Compare two amounts of the same currency: `{:ok, :lt | :eq | :gt}`."
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    with :ok <- same_currency(a, b), do: {:ok, Decimal.compare(a.amount, b.amount)}
  end

  @doc "True for an amount of exactly zero."
  def zero?(%__MODULE__{amount: amount}), do: Decimal.eq?(amount, 0)

  @doc "True for an amount above zero."
  def positive?(%__MODULE__{amount: amount}), do: Decimal.gt?(amount, 0)

  @doc "True for an amount below zero."
  def negative?(%__MODULE__{amount: amount}), do: Decimal.lt?(amount, 0)

  defp same_currency(%{currency: c}, %{currency: c}), do: :ok

  defp same_currency(a, b) do
    {:error,
     Error.business(
       entity: __MODULE__,
       operation: :arithmetic,
       code: :currency_mismatch,
       message: "cannot combine #{a.currency} with #{b.currency}",
       details: %{left: a.currency, right: b.currency}
     )}
  end

  defp invalid_amount(value) do
    {:error,
     Error.business(
       entity: __MODULE__,
       operation: :new,
       code: :invalid_amount,
       message: "#{inspect(value)} is not a valid amount"
     )}
  end

  defp to_decimal(%Decimal{} = d), do: {:ok, d}
  defp to_decimal(n) when is_integer(n), do: {:ok, Decimal.new(n)}
  defp to_decimal(n) when is_float(n), do: {:ok, Decimal.from_float(n)}

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, ""} -> {:ok, d}
      _ -> :error
    end
  end

  defp to_decimal(_), do: :error
end
