defmodule DDD.IdentityTest do
  use DDD.DataCase

  alias DDD.{Error, Identity, Migration, Type}

  defmodule Stocked do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :qty, :integer
    end
  end

  # A composite identity: the same SKU can exist in every tenant.
  defmodule Line do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :tenant_id, :uuid
      identity :sku, :string
      field :qty, :integer, default: 1
    end

    defop restock(line, qty) do
      line |> Map.put(:qty, line.qty + qty) |> emit_event(Stocked.new(%{qty: qty}))
    end

    defop move(line, sku), do: %{line | sku: sku}
  end

  defmodule Counter do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :code, :string
      field :n, :integer, default: 0
    end
  end

  defmodule Named do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :name, :string
    end
  end

  defmodule LineRepository do
    @moduledoc false
    use DDD.Repository

    repo Line do
      find_by :qty
    end
  end

  defmodule PgLineRepository do
    @moduledoc false
    use DDD.Repository.Ecto, port: DDD.IdentityTest.LineRepository, repo: DDD.TestRepo
  end

  defmodule PlainLineRepository do
    @moduledoc false
    use DDD.Repository

    repo Line do
    end
  end

  defmodule LineMemory do
    @moduledoc false
    use DDD.InMemoryRepository, port: DDD.IdentityTest.PlainLineRepository
  end

  @tenant "6f1f3a52-0b0a-4d6e-9d0b-7a9f3b1d2c11"

  defp line!(attrs \\ []) do
    {:ok, line} = Line.new(Keyword.merge([tenant_id: @tenant, sku: "A-1"], attrs))
    line
  end

  describe "the identity string" do
    test "one part is its own value, several are joined with :" do
      assert Line.identity(line!()) == "#{@tenant}:A-1"
      assert Line.identity_fields() == [:tenant_id, :sku]

      {:ok, counter} = Counter.new(code: "c-1")
      assert Counter.identity(counter) == "c-1"
      assert Counter.identity_fields() == [:code]
    end

    test "build_identity/1 makes the same string without an entity" do
      assert Line.build_identity(tenant_id: @tenant, sku: "A-1") == Line.identity(line!())
      assert Line.build_identity(%{sku: "A-1", tenant_id: @tenant}) == "#{@tenant}:A-1"
    end

    test "build_identity/1 raises for a missing part" do
      assert_raise ArgumentError, ~r/identity part :sku is missing/, fn ->
        Line.build_identity(tenant_id: @tenant)
      end

      assert_raise ArgumentError, ~r/:sku is missing/, fn ->
        Line.build_identity(tenant_id: @tenant, sku: nil)
      end
    end

    test "a : or \\ inside a part is escaped, so different parts never collide" do
      a = Identity.encode(["a:b", "c"])
      b = Identity.encode(["a", "b:c"])
      assert a == "a\\:b:c"
      assert b == "a:b\\:c"
      refute a == b

      assert Identity.decode(a) == ["a:b", "c"]
      assert Identity.decode(b) == ["a", "b:c"]
      assert Identity.decode(Identity.encode(["x\\", ":", "é:\\:"])) == ["x\\", ":", "é:\\:"]
      assert Identity.decode("single") == ["single"]
    end

    test "a single part is never escaped" do
      assert Identity.encode(["a:b"]) == "a:b"
    end

    test "two entities with the same parts have the same identity" do
      assert Line.identity(line!(qty: 5)) == Line.identity(line!(qty: 9))
    end
  end

  describe "creating" do
    test "every part of a composite identity is required, even a uuid" do
      assert {:error, error} = Line.new(sku: "A-1")
      assert [%{field: :tenant_id, code: :required}] = error.violations
      assert {:error, error} = Line.new(tenant_id: @tenant)
      assert [%{field: :sku, code: :required}] = error.violations
    end

    test "only a lone id of type :uuid is generated, and it is a UUIDv7" do
      assert {:ok, named} = Named.new(name: "x")
      assert String.at(named.id, 14) == "7"
      assert {:ok, same} = Named.new(id: named.id, name: "y")
      assert same.id == named.id
    end

    test "any other identity must be passed in" do
      assert {:error, error} = Counter.new(n: 1)
      assert [%{field: :code, code: :required}] = error.violations
    end

    test "a composite part is type-checked" do
      assert {:error, error} = Line.new(tenant_id: "nope", sku: "A-1")
      assert [%{field: :tenant_id, code: :invalid_type}] = error.violations
    end

    test "a part of a composite identity must have a plain text form" do
      assert_raise CompileError, ~r/must be a string, uuid, integer, atom, date or enum/, fn ->
        Code.compile_string("""
        defmodule DDD.IdentityTest.BadPart do
          use DDD.Aggregate

          aggregate do
            identity :a, :string
            identity :b, :decimal
          end
        end
        """)
      end
    end
  end

  describe "the identity never changes" do
    test "update/2 ignores identity parts" do
      line = line!()

      assert {:ok, updated} =
               Line.update(line, sku: "B-2", tenant_id: Ecto.UUID.generate(), qty: 4)

      assert updated.sku == "A-1"
      assert updated.tenant_id == @tenant
      assert updated.qty == 4
    end

    test "update/2 with a function cannot change it either" do
      assert {:error, %Error{kind: :business, code: :identity_changed}} =
               Line.update(line!(), &%{&1 | sku: "B-2"})

      assert {:ok, _} = Line.update(line!(), &%{&1 | qty: 3})
    end

    test "a defop that changes it is refused" do
      assert {:error, %Error{kind: :business, code: :identity_changed} = error} =
               Line.move(line!(), "B-2")

      assert error.operation == :move
      assert {:ok, _} = Line.move(line!(), "A-1")
    end
  end

  describe "events carry the identity string" do
    test "aggregate_id is the joined identity, also for a single field" do
      {:ok, line} = Line.restock(line!(), 3)
      {[event], _} = Line.pop_events(line)
      assert event.aggregate_id == "#{@tenant}:A-1"
      assert event.aggregate_type == "DDD.IdentityTest.Line"

      {:ok, counter} = Counter.new(code: "c-1")
      assert Counter.identity(counter) == "c-1"
    end
  end

  describe "references" do
    test "a ref to a composite aggregate holds its identity string" do
      assert Type.identity_type(Line) == :string
      assert Type.identity_type(Counter) == :string
      assert Type.identity_type(Named) == :uuid
      assert Type.valid?({:ref, Line}, "#{@tenant}:A-1")
      refute Type.valid?({:ref, Line}, 5)
      assert Type.ecto_type({:ref, Line}) == :string
    end

    test "an entity without identity can't be referenced" do
      assert_raise ArgumentError, ~r/no identity/, fn -> Type.identity_type(DDD.Money) end
    end
  end

  describe "in-memory repository" do
    test "stores a composite aggregate under its identity string" do
      start_supervised!(LineMemory)
      line = line!()
      assert {:ok, _} = LineMemory.save(line)
      assert {:ok, found} = LineMemory.find_by_id(Line.identity(line))
      assert found.sku == "A-1"
      assert {:error, :not_found} = LineMemory.find_by_id(@tenant)
      assert :ok = LineMemory.delete(line)
      assert LineMemory.count() == 0
    end
  end

  describe "Postgres" do
    setup do
      Repo.query!("""
      CREATE TEMP TABLE lines (
        identity varchar PRIMARY KEY, tenant_id uuid NOT NULL, sku varchar NOT NULL, qty bigint,
        created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
        version bigint NOT NULL DEFAULT 0
      )
      """)

      :ok
    end

    test "a composite aggregate is saved under its identity string and found by it" do
      {:ok, line} = Line.restock(line!(qty: 7), 1)
      assert {:ok, _} = PgLineRepository.save(line)

      assert %{rows: [[identity, sku, qty]]} =
               Repo.query!("SELECT identity, sku, qty FROM lines")

      assert identity == "#{@tenant}:A-1"
      assert {sku, qty} == {"A-1", 8}

      assert {:ok, found} = PgLineRepository.find_by_id(Line.identity(line))
      assert found.tenant_id == @tenant
      assert found.sku == "A-1"
      assert {:error, :not_found} = PgLineRepository.find_by_id("#{@tenant}:other")

      # The event is stored with the same identity string.
      assert %{rows: [["#{@tenant}:A-1"]]} =
               Repo.query!("SELECT aggregate_id FROM domain_events")
    end

    test "saving again updates the same row; a different SKU is another row" do
      assert {:ok, saved} = PgLineRepository.save(line!(qty: 1))
      {:ok, changed} = Line.update(saved, qty: 2)
      assert {:ok, _} = PgLineRepository.save(changed)
      assert {:ok, _} = PgLineRepository.save(line!(sku: "B-2"))

      assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM lines")
      assert {:ok, %{qty: 2}} = PgLineRepository.find_by_id("#{@tenant}:A-1")
      assert [%{sku: "A-1"}] = PgLineRepository.find_by_qty(2)

      assert :ok = PgLineRepository.delete(line!())
      assert {:error, :not_found} = PgLineRepository.find_by_id("#{@tenant}:A-1")
    end
  end

  describe "ids" do
    test "generate/0 is a UUIDv7" do
      assert <<_::8, _::binary>> = id = Identity.generate()
      assert {:ok, _} = Ecto.UUID.cast(id)
      assert String.at(id, 14) == "7"
      assert String.at(id, 19) in ~w(8 9 a b)
    end

    test "UUIDv7 ids made in different milliseconds sort in creation order" do
      ids =
        for _ <- 1..5 do
          Process.sleep(2)
          Identity.uuid7()
        end

      assert ids == Enum.sort(ids)
      assert length(Enum.uniq(ids)) == 5
    end

    test "the timestamp is in the id" do
      before = System.system_time(:millisecond)
      id = Identity.uuid7()
      <<millis::48, _::binary>> = Ecto.UUID.dump!(id)
      assert millis in before..System.system_time(:millisecond)
    end

    test "every generated id passes the :uuid type" do
      for id <- [Identity.generate(), Identity.uuid7()] do
        assert DDD.Type.valid?(:uuid, id)
      end
    end
  end

  describe "migrations" do
    @describetag :tmp_dir

    test "a composite aggregate gets an identity primary key and not-null parts", _ctx do
      columns = Migration.columns(Line)

      assert Enum.map(columns, & &1["name"]) ==
               ~w(identity tenant_id sku qty created_at updated_at version)

      assert %{"primary_key" => true, "type" => ":string"} = hd(columns)
      assert %{"null" => false, "primary_key" => false} = Enum.at(columns, 1)
      assert Migration.identity(Line) == ["tenant_id", "sku"]

      single = Migration.columns(Named)
      assert %{"name" => "id", "primary_key" => true} = hd(single)
      refute Enum.any?(single, &Map.has_key?(&1, "null"))
    end

    test "the generated create migration is valid and keeps the parts not null", %{tmp_dir: dir} do
      assert {:ok, path} = Migration.generate(Line, opts(dir))
      source = File.read!(path)
      assert source =~ "add :identity, :string, primary_key: true"
      assert source =~ "add :tenant_id, :binary_id, null: false"
      assert source =~ "add :sku, :string, null: false"
      assert {:ok, :unchanged} = Migration.generate(Line, opts(dir))
    end

    test "changing the identity is destructive and needs a backfill", %{tmp_dir: dir} do
      snapshot = Path.join([dir, "snapshots", "ddd.identity_test.line.json"])
      File.mkdir_p!(Path.dirname(snapshot))

      # An old single-field snapshot of the same table (no "identity" key).
      File.write!(
        snapshot,
        Jason.encode!(%{
          "table" => "lines",
          "columns" => [
            %{"name" => "id", "type" => ":binary_id", "primary_key" => true},
            %{"name" => "qty", "type" => ":integer", "primary_key" => false}
          ]
        })
      )

      assert {:error, {:destructive, summary}} = Migration.generate(Line, opts(dir))
      assert Enum.any?(summary, &(&1 =~ "change identity from [\"id\"]"))

      assert {:ok, path} = Migration.generate(Line, opts(dir, allow_destructive: true))
      source = File.read!(path)
      assert source =~ "TODO: the identity changed"
      assert source =~ "add :identity, :string\n"
      refute source =~ "primary_key: true"
      assert {:ok, :unchanged} = Migration.generate(Line, opts(dir))
    end

    test "a reordered identity is a change too", %{tmp_dir: dir} do
      assert {:ok, _} = Migration.generate(Line, opts(dir))
      snapshot = Path.join([dir, "snapshots", "ddd.identity_test.line.json"])
      data = snapshot |> File.read!() |> Jason.decode!()
      File.write!(snapshot, Jason.encode!(%{data | "identity" => ["sku", "tenant_id"]}))
      assert {:error, {:destructive, [summary]}} = Migration.generate(Line, opts(dir))
      assert summary =~ "change identity"
    end

    defp opts(dir, extra \\ []) do
      Keyword.merge(
        [
          snapshot_dir: Path.join(dir, "snapshots"),
          migrations_path: Path.join(dir, "migrations"),
          repo: MyApp.Repo,
          timestamp: "20300101000000"
        ],
        extra
      )
    end
  end
end
