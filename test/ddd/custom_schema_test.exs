defmodule DDD.CustomSchemaTest do
  # Not async: Mix.shell is global (DataCase is not async either).
  use DDD.DataCase

  @moduletag :capture_log

  defmodule Order do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :customer_id, :string, required: true
      field :status, :string, default: "new"
      field :extra, :json
    end

    defop ship(order) do
      Map.put(order, :status, "shipped")
    end
  end

  defmodule OrderPort do
    use DDD.Repository

    repo Order do
      find_by :status
    end
  end

  # An existing table: `customer_id` is called `cust_ref` there, and it has its own changeset.
  defmodule LegacyRecord do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "legacy_orders" do
      field :cust_ref, :string
      field :status, :string
      field :extra, DDD.Type.Json
      field :version, :integer, default: 0
      field :created_at, :utc_datetime_usec
      field :updated_at, :utc_datetime_usec
    end

    def changeset(_struct, _params), do: raise("the adapter must not call the schema's changeset")
  end

  defmodule LegacyOrders do
    use DDD.Repository.Ecto,
      port: OrderPort,
      repo: DDD.TestRepo,
      schema: DDD.CustomSchemaTest.LegacyRecord

    def to_domain(record), do: to_domain(record, customer_id: record.cust_ref)
    def from_domain(order), do: from_domain(order, cust_ref: order.customer_id)
  end

  # Same names as the aggregate: no overrides needed.
  defmodule Note do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :text, :string, required: true
    end
  end

  defmodule NotePort do
    use DDD.Repository

    repo Note do
    end
  end

  defmodule NoteRecord do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "cs_notes" do
      field :text, :string
      field :version, :integer, default: 0
      field :created_at, :utc_datetime_usec
      field :updated_at, :utc_datetime_usec
    end
  end

  defmodule Notes do
    use DDD.Repository.Ecto,
      port: NotePort,
      repo: DDD.TestRepo,
      schema: DDD.CustomSchemaTest.NoteRecord
  end

  defmodule GeneratedNotes do
    use DDD.Repository.Ecto, port: NotePort, repo: DDD.TestRepo, table: "cs_notes"
  end

  # A composite identity: stored whole in a string `identity` column, the primary key.
  defmodule Stock do
    use DDD.Aggregate

    aggregate do
      identity :tenant_id, :uuid
      identity :sku, :string
      field :qty, :integer, default: 1
    end
  end

  defmodule StockPort do
    use DDD.Repository

    repo Stock do
    end
  end

  defmodule StockRecord do
    use Ecto.Schema

    @primary_key {:identity, :string, autogenerate: false}
    schema "cs_stock" do
      field :tenant_id, :binary_id
      field :sku, :string
      field :qty, :integer
      field :version, :integer, default: 0
      field :created_at, :utc_datetime_usec
      field :updated_at, :utc_datetime_usec
    end
  end

  defmodule Stocks do
    use DDD.Repository.Ecto,
      port: StockPort,
      repo: DDD.TestRepo,
      schema: DDD.CustomSchemaTest.StockRecord
  end

  # Nested value objects live in one JSON column each.
  defmodule Address do
    use DDD.ValueObject

    value_object do
      field :street, :string, required: true
    end
  end

  defmodule Parcel do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :ship_to, {:one, Address}
      field :stops, {:list, Address}, default: []
    end
  end

  defmodule ParcelPort do
    use DDD.Repository

    repo Parcel do
    end
  end

  defmodule ParcelRecord do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "cs_parcels" do
      field :ship_to, :map
      field :stops, DDD.Type.Json
      field :version, :integer, default: 0
      field :created_at, :utc_datetime_usec
      field :updated_at, :utc_datetime_usec
    end
  end

  defmodule Parcels do
    use DDD.Repository.Ecto,
      port: ParcelPort,
      repo: DDD.TestRepo,
      schema: DDD.CustomSchemaTest.ParcelRecord
  end

  setup do
    DDD.TestRepo.query!("""
    CREATE TABLE cs_stock (
      identity varchar PRIMARY KEY, tenant_id uuid, sku varchar, qty bigint,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    DDD.TestRepo.query!("""
    CREATE TABLE cs_parcels (
      id uuid PRIMARY KEY, ship_to jsonb, stops jsonb,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    DDD.TestRepo.query!("""
    CREATE TABLE legacy_orders (
      id uuid PRIMARY KEY, cust_ref varchar, status varchar, extra jsonb,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    DDD.TestRepo.query!("""
    CREATE TABLE cs_notes (
      id uuid PRIMARY KEY, text varchar,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    :ok
  end

  describe "a schema you own" do
    test "maps by name with no overrides" do
      {:ok, note} = Note.new(text: "hello")
      assert {:ok, saved} = Notes.save(note)
      assert saved.version == 1
      assert {:ok, ^saved} = Notes.find_by_id(note.id)
      assert Notes.schema() == NoteRecord
      assert %{custom_schema?: true, schema: NoteRecord} = Notes.__ddd_adapter__()
    end

    test "maps a renamed field through the overrides, and keeps the lock" do
      {:ok, order} = Order.new(customer_id: "c-1", extra: %{"a" => [1, 2]})
      assert {:ok, saved} = LegacyOrders.save(order)

      assert %{rows: [["c-1", 1]]} =
               DDD.TestRepo.query!("SELECT cust_ref, version FROM legacy_orders")

      assert {:ok, ^saved} = LegacyOrders.find_by_id(order.id)
      assert saved.customer_id == "c-1"
      assert saved.extra == %{"a" => [1, 2]}
      assert [^saved] = LegacyOrders.find_by_status("new")
      assert LegacyOrders.count() == {:ok, 1}

      {:ok, shipped} = Order.ship(saved)
      assert {:ok, %{version: 2, status: "shipped"}} = LegacyOrders.save(shipped)

      # Saved at version 1 again: someone else got to version 2 first.
      {:ok, stale} = Order.ship(saved)
      assert {:error, %DDD.Error{code: :stale_aggregate}} = LegacyOrders.save(stale)

      assert :ok = LegacyOrders.delete(shipped)
      assert {:error, :not_found} = LegacyOrders.find_by_id(order.id)
    end

    test "to_domain/2 and from_domain/2 default to the by-name mapping" do
      {:ok, order} = Order.new(customer_id: "c-2")
      params = LegacyOrders.from_domain(order, cust_ref: "x")
      assert %{cust_ref: "x", customer_id: "c-2", status: "new"} = params
    end
  end

  describe "composite identity and nested entities" do
    @tenant "6f1f3a52-0b0a-4d6e-9d0b-7a9f3b1d2c11"

    test "a composite identity is stored whole in the schema's identity column" do
      {:ok, stock} = Stock.new(tenant_id: @tenant, sku: "A-1", qty: 4)
      assert {:ok, saved} = Stocks.save(stock)

      assert %{rows: [["#{@tenant}:A-1", @tenant, "A-1", 4]]} ==
               DDD.TestRepo.query!("SELECT identity, tenant_id::text, sku, qty FROM cs_stock")
               |> Map.take([:rows])

      assert {:ok, ^saved} = Stocks.find_by_id("#{@tenant}:A-1")
      assert {:ok, %{version: 2}} = Stocks.save(saved)
    end

    test "nested entities round-trip through their JSON columns" do
      {:ok, home} = Address.new(street: "Main 1")
      {:ok, work} = Address.new(street: "Dock 9")
      {:ok, parcel} = Parcel.new(ship_to: home, stops: [home, work])

      assert {:ok, saved} = Parcels.save(parcel)
      assert {:ok, loaded} = Parcels.find_by_id(parcel.id)
      assert loaded == saved
      assert %Address{street: "Main 1"} = loaded.ship_to
      assert [%Address{street: "Main 1"}, %Address{street: "Dock 9"}] = loaded.stops
      assert :ok = DDD.Migration.schema_drift(Parcels)
    end

    test "a nested field stored as a plain string is refused when the adapter compiles" do
      Code.compile_string("""
      defmodule DDD.CustomSchemaTest.StringParcel do
        use Ecto.Schema
        @primary_key {:id, :binary_id, autogenerate: false}
        schema "cs_parcels" do
          field :ship_to, :string
          field :stops, DDD.Type.Json
          field :version, :integer
          field :created_at, :utc_datetime_usec
          field :updated_at, :utc_datetime_usec
        end
      end
      """)

      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule DDD.CustomSchemaTest.StringParcelAdapter do
            use DDD.Repository.Ecto,
              port: DDD.CustomSchemaTest.ParcelPort,
              repo: DDD.TestRepo,
              schema: DDD.CustomSchemaTest.StringParcel
          end
          """)
        end

      assert Exception.message(error) =~ ":ship_to is stored as JSON"
    end
  end

  describe "compile-time check" do
    defp compile!(source), do: Code.compile_string(source)

    defp schema_source(name, fields, pk \\ "{:id, :binary_id, autogenerate: false}") do
      """
      defmodule #{name} do
        use Ecto.Schema
        @primary_key #{pk}
        schema "legacy_orders" do
      #{fields}
        end
      end
      """
    end

    @full_fields """
        field :cust_ref, :string
        field :customer_id, :string
        field :status, :string
        field :extra, DDD.Type.Json
        field :version, :integer
        field :created_at, :utc_datetime_usec
        field :updated_at, :utc_datetime_usec
    """

    defp adapter_source(schema, body \\ "") do
      "defmodule #{schema}Adapter do\n" <>
        "  use DDD.Repository.Ecto, port: DDD.CustomSchemaTest.OrderPort, " <>
        "repo: DDD.TestRepo, schema: #{schema}\n#{body}\nend"
    end

    test "schema: and table: together are refused" do
      assert_raise ArgumentError, ~r/either `schema:`.*or `table:`/, fn ->
        compile!(
          "defmodule DDD.CustomSchemaTest.Both do\n" <>
            "  use DDD.Repository.Ecto, port: DDD.CustomSchemaTest.OrderPort, " <>
            "repo: DDD.TestRepo, schema: DDD.CustomSchemaTest.LegacyRecord, table: \"t\"\nend"
        )
      end
    end

    test "lists the aggregate fields the schema has no field for" do
      compile!(
        schema_source("DDD.CustomSchemaTest.NoCustomer", """
            field :status, :string
            field :extra, DDD.Type.Json
            field :version, :integer
            field :created_at, :utc_datetime_usec
            field :updated_at, :utc_datetime_usec
        """)
      )

      error =
        assert_raise CompileError, fn ->
          compile!(adapter_source("DDD.CustomSchemaTest.NoCustomer"))
        end

      assert Exception.message(error) =~ "no schema field for :customer_id"
    end

    test "overriding the mapping skips that check but not the primary key or version" do
      compile!(
        schema_source("DDD.CustomSchemaTest.Renamed", """
            field :cust_ref, :string
            field :version, :integer
        """)
      )

      overrides = "def to_domain(r), do: to_domain(r, customer_id: r.cust_ref)"
      assert [{_, _} | _] = compile!(adapter_source("DDD.CustomSchemaTest.Renamed", overrides))

      compile!(schema_source("DDD.CustomSchemaTest.NoVersion", "field :cust_ref, :string"))

      error =
        assert_raise CompileError, fn ->
          compile!(adapter_source("DDD.CustomSchemaTest.NoVersion", overrides))
        end

      assert Exception.message(error) =~ "no :version field"
    end

    test "refuses a primary key that is not the aggregate's identity" do
      compile!(
        schema_source("DDD.CustomSchemaTest.OtherPk", @full_fields, "{:uid, :binary_id, []}")
      )

      error =
        assert_raise CompileError, fn ->
          compile!(adapter_source("DDD.CustomSchemaTest.OtherPk"))
        end

      assert Exception.message(error) =~ "its primary key is [:uid], expected [:id]"

      compile!(schema_source("DDD.CustomSchemaTest.IntPk", @full_fields, "{:id, :integer, []}"))

      error =
        assert_raise CompileError, fn ->
          compile!(adapter_source("DDD.CustomSchemaTest.IntPk", "def to_domain(r), do: r"))
        end

      assert Exception.message(error) =~ "primary key :id is :integer"
    end

    test "refuses a JSON field that is not DDD.Type.Json" do
      compile!(
        schema_source(
          "DDD.CustomSchemaTest.PlainMap",
          String.replace(@full_fields, "DDD.Type.Json", ":string")
        )
      )

      error =
        assert_raise CompileError, fn ->
          compile!(adapter_source("DDD.CustomSchemaTest.PlainMap"))
        end

      assert Exception.message(error) =~ ":extra is stored as JSON"
    end

    test "refuses a module that is not an Ecto schema" do
      error =
        assert_raise CompileError, fn ->
          compile!(adapter_source("Enum"))
        end

      assert Exception.message(error) =~ "it is not an Ecto schema"
    end
  end

  describe "drift" do
    test "schema_drift reports the aggregate/schema mismatch, and accepts renames" do
      assert {:error, %{missing_in_schema: ["customer_id"], extra_in_schema: ["cust_ref"]}} =
               DDD.Migration.schema_drift(LegacyOrders)

      assert :ok = DDD.Migration.schema_drift(LegacyOrders, %{"customer_id" => "cust_ref"})
      assert :ok = DDD.Migration.schema_drift(Notes)
      assert :ok = DDD.Migration.schema_drift(GeneratedNotes)
    end

    test "table_drift compares the schema with the real table" do
      assert :ok = DDD.Migration.table_drift(LegacyOrders)
      assert :ok = DDD.Migration.table_drift(GeneratedNotes)

      DDD.TestRepo.query!("ALTER TABLE legacy_orders ADD COLUMN surprise varchar")
      DDD.TestRepo.query!("ALTER TABLE legacy_orders DROP COLUMN extra")

      assert {:error, %{missing_in_db: ["extra"], extra_in_db: ["surprise"]}} =
               DDD.Migration.table_drift(LegacyOrders)
    end
  end

  describe "mix vic.gen.migration" do
    @describetag :tmp_dir

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      :ok
    end

    defp args(dir, aggregate) do
      [
        aggregate,
        "--snapshot-dir",
        Path.join(dir, "snap"),
        "--migrations-path",
        Path.join(dir, "mig")
      ]
    end

    test "skips an aggregate stored through your own schema", %{tmp_dir: dir} do
      Mix.Tasks.Vic.Gen.Migration.run(args(dir, "DDD.CustomSchemaTest.Order"))

      assert_received {:mix_shell, :info, [message]}
      assert message =~ "DDD.CustomSchemaTest.Order: skipped"
      assert message =~ "DDD.CustomSchemaTest.LegacyRecord"
      refute File.exists?(Path.join(dir, "mig"))
    end

    test "still generates when one adapter of the aggregate has a generated schema",
         %{tmp_dir: dir} do
      # Note is stored both ways (Notes: yours, GeneratedNotes: generated).
      Mix.Tasks.Vic.Gen.Migration.run(args(dir, "DDD.CustomSchemaTest.Note"))

      assert_received {:mix_shell, :info, [created]}
      assert IO.iodata_to_binary(created) =~ "create_notes"
    end
  end
end
