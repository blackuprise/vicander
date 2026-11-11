defmodule DDD.TypesTest do
  use ExUnit.Case, async: true

  alias DDD.{Error, Type}

  defmodule Customer do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :name, :string
    end
  end

  defmodule Address do
    use DDD.ValueObject

    value_object do
      field :street, :string, required: true
      field :zip, :string
    end
  end

  defmodule Order do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :note, :text
      field :status, {:enum, [:open, :paid]}, default: :open
      field :tags, {:array, :string}, default: []
      field :customer_id, {:ref, Customer}
      field :total, :money
      field :prices, {:map, :money}
      field :ship_to, {:one, Address}
      field :billing, {:list, Address}, default: []
      field :opened_on, :date
      field :opens_at, :time
      field :seen, :naive_datetime
      field :paid_at, :datetime
      field :blob, :binary
      field :meta, :json
      field :scores, {:array, :decimal}, default: []
      field :kinds, {:array, {:enum, [:a, :b]}}, default: []
    end
  end

  defp order!(attrs) do
    {:ok, order} = Order.new(attrs)
    order
  end

  describe "validity" do
    test "a correctly typed order is valid" do
      {:ok, total} = DDD.Money.of("10.00", "EUR")
      {:ok, home} = Address.new(street: "Main 1")

      assert {:ok, _} =
               Order.new(
                 note: "long text",
                 status: :paid,
                 tags: ["a", "b"],
                 customer_id: Ecto.UUID.generate(),
                 total: total,
                 prices: %{"base" => total},
                 ship_to: home,
                 billing: [home],
                 opened_on: ~D[2030-01-01],
                 opens_at: ~T[10:00:00.123456],
                 seen: ~N[2030-01-01 10:00:00.5],
                 paid_at: ~U[2030-01-01 10:00:00Z],
                 blob: <<1, 2, 3>>,
                 meta: [1, %{"a" => 2}],
                 scores: [Decimal.new("1.5")],
                 kinds: [:a, :b]
               )
    end

    test "nil is accepted by every type" do
      assert {:ok, _} = Order.new([])
    end

    test "every mistyped field is reported with :invalid_type" do
      assert {:error, %Error{} = error} =
               Order.new(
                 note: 1,
                 status: :gone,
                 tags: ["a", 2],
                 customer_id: "nope",
                 total: "10 EUR",
                 prices: %{"base" => 1},
                 ship_to: %{street: "x"},
                 billing: [1],
                 opened_on: "2030-01-01",
                 opens_at: 5,
                 seen: ~D[2030-01-01],
                 paid_at: "now",
                 blob: 1,
                 meta: "text",
                 scores: [1],
                 kinds: [:c]
               )

      fields = error.violations |> Enum.map(& &1.field) |> Enum.sort()

      assert fields ==
               ~w(billing blob customer_id kinds meta note opened_on opens_at paid_at prices scores seen ship_to status tags total)a

      assert Enum.all?(error.violations, &(&1.code == :invalid_type))
    end

    test "the message says what was expected" do
      assert {:error, error} = Order.new(status: :gone)
      assert [%{message: "must be one of [:open, :paid]"}] = error.violations
    end

    test "false is checked like any other value" do
      assert false == Type.valid?(:integer, false)
      assert true == Type.valid?(:boolean, false)
    end

    test "rules are skipped for a mistyped field, so they never crash" do
      defmodule Rules do
        use DDD.ValueObject

        value_object do
          field :code, :string
          validate :code, &(String.length(&1) > 2), message: "too short"
        end
      end

      assert {:error, error} = Rules.new(code: 5)
      assert Error.codes(error) == [:invalid_type]
      assert {:error, error} = Rules.new(code: "ab")
      assert Error.codes(error) == [:invalid]
    end

    test "floats accept integers; :json accepts maps and lists but not structs" do
      assert Type.valid?(:float, 1)
      assert Type.valid?(:json, %{"a" => 1})
      assert Type.valid?(:json, [1])
      refute Type.valid?(:json, ~D[2030-01-01])
      refute Type.valid?(:map, ~D[2030-01-01])
      assert Type.valid?(:list, [1])
      assert Type.valid?({:map, :integer}, %{a: 1})
      refute Type.valid?({:map, :integer}, %{1 => 1})
      refute Type.valid?(:unknown, 1)
    end

    test "a ref has the type of the referenced identity" do
      assert Type.valid?({:ref, Customer}, Ecto.UUID.generate())
      refute Type.valid?({:ref, Customer}, "x")
      assert Type.identity_type(Customer) == :uuid
    end

    test "a ref needs an aggregate with an identity" do
      assert_raise ArgumentError, ~r/no identity/, fn -> Type.identity_type(Address) end
    end
  end

  describe "declaring types" do
    test ":money expands, scalars pass, mistakes raise" do
      assert Type.normalize!(:money) == {:one, DDD.Money}
      assert Type.normalize!({:array, :money}) == {:array, {:one, DDD.Money}}
      assert Type.normalize!({:map, :string}) == {:map, :string}
      assert Type.normalize!({:enum, [:a]}) == {:enum, [:a]}
      assert Type.normalize!({:ref, Customer}) == {:ref, Customer}
    end

    test "unknown types, bad enums and arrays of arrays raise" do
      assert_raise ArgumentError, ~r/unknown field type/, fn -> Type.normalize!(:strng) end
      assert_raise ArgumentError, ~r/enum values/, fn -> Type.normalize!({:enum, ["a"]}) end
      assert_raise ArgumentError, ~r/enum values/, fn -> Type.normalize!({:enum, [nil]}) end

      assert_raise ArgumentError, ~r/arrays of arrays/, fn ->
        Type.normalize!({:array, {:array, :string}})
      end

      assert_raise ArgumentError, ~r/unknown field type/, fn -> Type.normalize!({:enum, []}) end
    end

    test "a typo in a field fails to compile" do
      assert_raise ArgumentError, ~r/unknown field type/, fn ->
        Code.compile_string("""
        defmodule DDD.TypesTest.Typo do
          use DDD.ValueObject
          value_object do
            field :x, :strng
          end
        end
        """)
      end
    end

    test "describe/1 names every kind" do
      assert Type.describe({:array, :string}) == "a list of a string"
      assert Type.describe({:map, :integer}) == "a map of a integer"
      assert Type.describe({:ref, Customer}) =~ "the id of"
      assert Type.describe({:one, Address}) =~ "a DDD.TypesTest.Address"
      assert Type.describe({:list, Address}) =~ "a list of"
    end
  end

  describe "Postgres types" do
    test "ecto_type and column_type" do
      assert Type.ecto_type(:string) == :string
      assert Type.ecto_type(:text) == :string
      assert Type.ecto_type(:atom) == :string
      assert Type.ecto_type(:uuid) == :binary_id
      assert Type.ecto_type(:time) == :time_usec
      assert Type.ecto_type(:naive_datetime) == :naive_datetime_usec
      assert Type.ecto_type(:datetime) == :utc_datetime
      assert Type.ecto_type(:datetime_usec) == :utc_datetime_usec
      assert Type.ecto_type(:json) == DDD.Type.Json
      assert Type.ecto_type(:list) == DDD.Type.Json
      assert Type.ecto_type({:enum, [:a]}) == :string
      assert Type.ecto_type({:ref, Customer}) == :binary_id
      assert Type.ecto_type({:one, Address}) == :map
      assert Type.ecto_type({:map, :money}) == :map
      assert Type.ecto_type({:list, Address}) == DDD.Type.Json
      assert Type.ecto_type({:array, :string}) == {:array, :string}
      assert Type.ecto_type({:array, :json}) == DDD.Type.Json
      assert Type.ecto_type({:array, {:one, Address}}) == DDD.Type.Json

      assert Type.column_type(:text) == :text
      assert Type.column_type({:array, :text}) == {:array, :text}
      assert Type.column_type(:json) == :map
      assert Type.column_type(:integer) == :integer
    end

    test "dump and load round-trip every kind of value" do
      {:ok, total} = DDD.Money.of("10.00", "EUR")
      {:ok, home} = Address.new(street: "Main 1")

      cases = [
        {:atom, :hello, "hello"},
        {{:enum, [:open, :paid]}, :paid, "paid"},
        {:float, 2, 2.0},
        {{:array, :atom}, [:a, :b], ["a", "b"]},
        {{:array, {:enum, [:a, :b]}}, [:b], ["b"]},
        {{:ref, Customer}, "6f1f3a52-0b0a-4d6e-9d0b-7a9f3b1d2c11",
         "6f1f3a52-0b0a-4d6e-9d0b-7a9f3b1d2c11"},
        {:integer, 3, 3}
      ]

      for {type, value, dumped} <- cases do
        assert Type.dump(type, value) == dumped
        loaded = Type.load(type, dumped)
        assert loaded == if(type == :float, do: 2.0, else: value)
      end

      assert Type.dump(:integer, nil) == nil
      assert Type.load(:integer, nil) == nil

      assert %{"amount" => "10.00", "currency" => "EUR"} = Type.dump({:one, DDD.Money}, total)
      assert Type.dump({:list, Address}, [home]) |> hd() |> Map.fetch!("street") == "Main 1"
      assert Type.dump({:map, {:one, DDD.Money}}, %{base: total})["base"]["currency"] == "EUR"

      assert %DDD.Money{currency: "EUR"} =
               Type.json_load({:one, DDD.Money}, Type.dump({:one, DDD.Money}, total))
    end

    test "an enum value that is no longer listed is read back as stored" do
      assert Type.load({:enum, [:a]}, "gone") == "gone"
      assert Type.load({:enum, [:a]}, :a) == :a
      assert Type.load({:enum, [:a]}, "a") == :a
    end
  end

  describe "JSON" do
    test "every type round-trips through JSON text" do
      {:ok, total} = DDD.Money.of("10.00", "EUR")
      {:ok, home} = Address.new(street: "Main 1")

      order =
        order!(
          note: "n",
          status: :paid,
          tags: ["a"],
          customer_id: Ecto.UUID.generate(),
          total: total,
          prices: %{"base" => total},
          ship_to: home,
          billing: [home],
          opened_on: ~D[2030-01-01],
          opens_at: ~T[10:00:00.123456],
          seen: ~N[2030-01-01 10:00:00.500000],
          paid_at: ~U[2030-01-01 10:00:00.000000Z],
          blob: <<0, 255, 1>>,
          meta: %{"a" => [1, 2]},
          scores: [Decimal.new("1.5")],
          kinds: [:a]
        )

      json = order |> DDD.Serializer.dump() |> Jason.encode!()
      loaded = Order |> DDD.Serializer.load(Jason.decode!(json))

      assert loaded.opens_at == ~T[10:00:00.123456]
      assert loaded.seen == ~N[2030-01-01 10:00:00.500000]
      assert loaded.blob == <<0, 255, 1>>
      assert loaded.prices["base"].amount == Decimal.new("10.00")
      assert loaded.ship_to.street == "Main 1"
      assert loaded.kinds == [:a]
      assert loaded.scores == [Decimal.new("1.5")]
      assert DDD.Schema.sealed?(loaded)
      assert loaded == %{loaded | __sealed__: loaded.__sealed__}
    end

    test "decimals also load from JSON numbers" do
      assert Type.json_load(:decimal, 5) == Decimal.new(5)
      assert Type.json_load(:decimal, 1.5) == Decimal.from_float(1.5)
    end
  end

  describe "DDD.Type.Json" do
    test "accepts maps and lists only" do
      alias DDD.Type.Json
      assert Json.type() == :map
      assert Json.cast([1]) == {:ok, [1]}
      assert Json.cast(%{}) == {:ok, %{}}
      assert Json.cast("x") == :error
      assert Json.dump([1]) == {:ok, [1]}
      assert Json.dump("x") == :error
      assert Json.load([1]) == {:ok, [1]}
    end
  end
end
