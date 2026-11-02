defmodule DDD.SerializerTest do
  use ExUnit.Case, async: true

  alias DDD.Serializer

  defmodule Tag do
    use DDD.ValueObject

    value_object do
      field :label, :string, required: true
    end
  end

  defmodule Part do
    use DDD.Entity

    entity do
      identity :id, :uuid
      field :tag, {:one, Tag}
      field :state, :atom, default: :new
      field :price, :decimal
      field :due, :date
      field :seen_at, :datetime
      field :note, :string, default: "none"
    end
  end

  defmodule Box do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :parts, {:list, Part}, default: []
    end
  end

  setup do
    {:ok, tag} = Tag.new(label: "red")

    {:ok, part} =
      Part.new(
        tag: tag,
        state: :ready,
        price: Decimal.new("9.50"),
        due: ~D[2030-01-02],
        seen_at: ~U[2030-01-02 03:04:05.123456Z]
      )

    %{part: part}
  end

  test "dump/1 produces a JSON-encodable map with string keys", %{part: part} do
    dumped = Serializer.dump(part)

    assert dumped["state"] == "ready"
    assert dumped["price"] == "9.50"
    assert dumped["due"] == "2030-01-02"
    assert dumped["seen_at"] == "2030-01-02T03:04:05.123456Z"
    assert dumped["tag"] == %{"label" => "red"}
    assert {:ok, _json} = Jason.encode(dumped)
  end

  test "load(dump(x)) round-trips and seals", %{part: part} do
    loaded =
      part
      |> Serializer.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> then(&Serializer.load(Part, &1))

    assert DDD.Schema.sealed?(loaded)
    assert loaded.id == part.id
    assert loaded.state == :ready
    assert Decimal.equal?(loaded.price, part.price)
    assert loaded.due == part.due
    assert loaded.seen_at == part.seen_at
    assert %Tag{label: "red"} = loaded.tag
    assert DDD.Schema.sealed?(loaded.tag)
  end

  test "lists of entities round-trip through dump_value/2 and load_value/2", %{part: part} do
    dumped = Serializer.dump_value({:list, Part}, [part, part])

    assert [%Part{}, %Part{}] =
             Serializer.load_value({:list, Part}, Jason.decode!(Jason.encode!(dumped)))
  end

  test "keys missing from old rows take the field default" do
    loaded = Serializer.load(Part, %{"id" => "abc", "tag" => nil})
    assert loaded.note == "none"
    assert loaded.state == :new
    assert loaded.tag == nil
    assert loaded.price == nil
  end

  test "atom keys are accepted too" do
    assert %Part{note: "hi"} = Serializer.load(Part, %{id: "abc", note: "hi"})
  end

  test "nil and scalar values pass through" do
    assert Serializer.dump_value({:list, Part}, nil) == nil
    assert Serializer.dump_value({:one, Part}, nil) == nil
    assert Serializer.dump_value(:string, "x") == "x"
    assert Serializer.load_value({:list, Part}, nil) == nil
    assert Serializer.load_value(:string, "x") == "x"
  end

  test "aggregates with nested lists introspect their types" do
    assert {:parts, {:list, Part}, _} = List.keyfind(Box.__ddd_fields__(), :parts, 0)
  end
end
