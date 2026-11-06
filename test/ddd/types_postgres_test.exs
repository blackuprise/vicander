defmodule DDD.TypesPostgresTest do
  # Every field type, saved to and read back from a real Postgres table.
  use DDD.DataCase

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
    end
  end

  defmodule Order do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :note, :text
      field :count, :integer
      field :ratio, :float
      field :flag, :boolean
      field :kind, :atom
      field :status, {:enum, [:open, :paid]}, default: :open
      field :tags, {:array, :string}, default: []
      field :scores, {:array, :decimal}, default: []
      field :kinds, {:array, {:enum, [:a, :b]}}, default: []
      field :customer_id, {:ref, Customer}
      field :total, :money
      field :prices, {:map, :money}
      field :ship_to, {:one, Address}
      field :billing, {:list, Address}, default: []
      field :amount, :decimal
      field :opened_on, :date
      field :opens_at, :time
      field :seen, :naive_datetime
      field :paid_at, :datetime
      field :blob, :binary
      field :meta, :json
      field :bag, :map
    end
  end

  defmodule OrderRepository do
    use DDD.Repository

    repo Order do
      find_by :status
    end
  end

  defmodule PgOrderRepository do
    use DDD.Repository.Ecto, port: DDD.TypesPostgresTest.OrderRepository, repo: DDD.TestRepo
  end

  setup do
    Repo.query!("""
    CREATE TEMP TABLE orders (
      id uuid PRIMARY KEY, note text, count bigint, ratio float8, flag boolean,
      kind varchar, status varchar, tags varchar[], scores numeric[], kinds varchar[],
      customer_id uuid, total jsonb, prices jsonb, ship_to jsonb, billing jsonb,
      amount numeric, opened_on date, opens_at time(6), seen timestamp(6),
      paid_at timestamp(0), blob bytea, meta jsonb, bag jsonb,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
        version bigint NOT NULL DEFAULT 0
    )
    """)

    :ok
  end

  test "every field type survives a save and a read" do
    {:ok, total} = DDD.Money.of("19.99", "EUR")
    {:ok, home} = Address.new(street: "Main 1")
    customer_id = UUID.uuid4()

    {:ok, order} =
      Order.new(
        note: "a long note",
        count: 3,
        ratio: 0.5,
        flag: false,
        kind: :special,
        status: :paid,
        tags: ["x", "y"],
        scores: [Decimal.new("1.5"), Decimal.new("2")],
        kinds: [:b, :a],
        customer_id: customer_id,
        total: total,
        prices: %{"base" => total},
        ship_to: home,
        billing: [home, home],
        amount: Decimal.new("123.456"),
        opened_on: ~D[2030-01-02],
        opens_at: ~T[10:11:12.123456],
        seen: ~N[2030-01-02 10:11:12.250000],
        paid_at: ~U[2030-01-02 10:11:12Z],
        blob: <<0, 255, 7>>,
        meta: [1, %{"a" => "b"}],
        bag: %{"k" => 1}
      )

    assert {:ok, saved} = PgOrderRepository.save(order)
    assert {:ok, found} = PgOrderRepository.find_by_id(order.id)

    for loaded <- [saved, found] do
      assert loaded.note == "a long note"
      assert loaded.count == 3
      assert loaded.ratio == 0.5
      assert loaded.flag == false
      assert loaded.kind == :special
      assert loaded.status == :paid
      assert loaded.tags == ["x", "y"]
      assert loaded.scores == [Decimal.new("1.5"), Decimal.new("2")]
      assert loaded.kinds == [:b, :a]
      assert loaded.customer_id == customer_id
      assert loaded.total.amount == Decimal.new("19.99")
      assert loaded.total.currency == "EUR"
      assert loaded.prices["base"].currency == "EUR"
      assert loaded.ship_to.street == "Main 1"
      assert [%Address{}, %Address{}] = loaded.billing
      assert Decimal.eq?(loaded.amount, "123.456")
      assert loaded.opened_on == ~D[2030-01-02]
      assert loaded.opens_at == ~T[10:11:12.123456]
      assert loaded.seen == ~N[2030-01-02 10:11:12.250000]
      assert loaded.paid_at == ~U[2030-01-02 10:11:12Z]
      assert loaded.blob == <<0, 255, 7>>
      assert loaded.meta == [1, %{"a" => "b"}]
      assert loaded.bag == %{"k" => 1}
      assert DDD.Schema.sealed?(loaded)
    end

    assert [%{id: id}] = PgOrderRepository.find_by_status(:paid)
    assert id == order.id
  end

  test "every field type survives a batched insert and a batched update" do
    {:ok, total} = DDD.Money.of("19.99", "EUR")
    {:ok, home} = Address.new(street: "Main 1")

    new_order = fn n ->
      {:ok, order} =
        Order.new(
          note: "note #{n}",
          count: n,
          ratio: 0.5,
          flag: true,
          kind: :special,
          status: :paid,
          tags: ["x", "y"],
          scores: [Decimal.new("1.5")],
          kinds: [:b, :a],
          customer_id: UUID.uuid4(),
          total: total,
          prices: %{"base" => total},
          ship_to: home,
          billing: [home, home],
          amount: Decimal.new("123.456"),
          opened_on: ~D[2030-01-02],
          opens_at: ~T[10:11:12.123456],
          seen: ~N[2030-01-02 10:11:12.250000],
          paid_at: ~U[2030-01-02 10:11:12Z],
          blob: <<0, 255, 7>>,
          meta: [1, %{"a" => "b"}],
          bag: %{"k" => 1}
        )

      order
    end

    orders = Enum.map(1..5, new_order)

    # One flush inserts all five.
    assert {:ok, _} =
             DDD.UnitOfWork.run(fn ->
               for order <- orders, do: {:ok, _} = PgOrderRepository.save(order)
               {:ok, :saved}
             end)

    for order <- orders do
      assert {:ok, %{version: 1, count: count, tags: ["x", "y"]}} =
               PgOrderRepository.find_by_id(order.id)

      assert count == String.to_integer(String.replace(order.note, "note ", ""))
    end

    # One flush updates all five; some fields go back to nothing, which must be written.
    assert {:ok, _} =
             DDD.UnitOfWork.run(fn ->
               for order <- orders do
                 {:ok, loaded} = PgOrderRepository.find_by_id(order.id)

                 {:ok, changed} =
                   Order.update(loaded,
                     note: nil,
                     tags: [],
                     total: nil,
                     ship_to: nil,
                     meta: nil,
                     paid_at: nil,
                     amount: Decimal.new("0.5"),
                     bag: %{"k" => 2}
                   )

                 {:ok, _} = PgOrderRepository.save(changed)
               end

               {:ok, :saved}
             end)

    for order <- orders do
      assert {:ok, found} = PgOrderRepository.find_by_id(order.id)
      assert found.version == 2
      assert found.note == nil
      assert found.tags == []
      assert found.total == nil
      assert found.ship_to == nil
      assert found.meta == nil
      assert found.paid_at == nil
      assert Decimal.eq?(found.amount, "0.5")
      assert found.bag == %{"k" => 2}
      # What was not touched is untouched.
      assert found.kinds == [:b, :a]
      assert found.billing |> length() == 2
      assert found.opens_at == ~T[10:11:12.123456]
      assert found.blob == <<0, 255, 7>>
    end
  end

  test "empty values come back as the declared defaults" do
    {:ok, order} = Order.new([])
    assert {:ok, _} = PgOrderRepository.save(order)
    assert {:ok, found} = PgOrderRepository.find_by_id(order.id)
    assert found.status == :open
    assert found.tags == []
    assert found.total == nil
    assert found.meta == nil
  end

  test "the migration generator knows the column types" do
    types =
      for %{"name" => name, "type" => type} <- DDD.Migration.columns(Order), into: %{} do
        {name, type}
      end

    assert types["note"] == ":text"
    assert types["tags"] == "{:array, :string}"
    assert types["customer_id"] == ":binary_id"
    assert types["opens_at"] == ":time_usec"
    assert types["seen"] == ":naive_datetime_usec"
    assert types["meta"] == ":map"
    assert types["status"] == ":string"
    assert types["billing"] == ":map"
    assert types["total"] == ":map"
  end
end
