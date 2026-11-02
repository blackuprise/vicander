defmodule DDD.ProjectionTest do
  use DDD.DataCase

  @moduletag :capture_log

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias DDD.Outbox.Poller

  for name <- ~w(Created Added Done Removed Renamed Closed Touch Both Rate Reject Skip Ignored
                 BadField WrongReturn BadInc UnknownInc StringInc KeyChange Ping)a do
    defmodule Module.concat(__MODULE__, name) do
      use DDD.DomainEvent

      domain_event do
        field :owner_id, :string
        field :title, :string
      end
    end
  end

  alias DDD.ProjectionTest.{
    Added,
    BadField,
    BadInc,
    Both,
    Closed,
    Created,
    Done,
    Ignored,
    KeyChange,
    Ping,
    Rate,
    Reject,
    Removed,
    Renamed,
    Skip,
    StringInc,
    Touch,
    UnknownInc,
    WrongReturn
  }

  defmodule Summary do
    use DDD.Projection,
      table: "projection_summaries",
      key: :list_id,
      events: [
        Created,
        Added,
        Done,
        Removed,
        Renamed,
        Closed,
        Touch,
        Both,
        Rate,
        Reject,
        Skip,
        Ignored,
        BadField,
        WrongReturn,
        BadInc,
        UnknownInc,
        StringInc,
        KeyChange
      ]

    projection do
      description "One row per list"
      field :list_id, :uuid
      field :owner_id, :string
      field :title, :string
      field :open_count, :integer, default: 0
      field :done_count, :integer, default: 0
      field :ratio, :float, default: 0.0
    end

    on %Created{} = e, do: {:upsert, %{owner_id: e.owner_id, title: e.title}}
    on %Added{}, do: {:inc, :open_count, 1}
    on %Done{}, do: {:inc, open_count: -1, done_count: 1}
    on %Removed{}, do: {:inc, :open_count, -1}
    on %Renamed{} = e, do: {:update, %{title: e.title}}
    on %Closed{}, do: :delete
    on %Touch{}, do: {:upsert, %{}}
    on %Both{} = e, do: [{:upsert, %{title: e.title}}, {:inc, :open_count, 5}]
    on %Rate{}, do: {:inc, :ratio, 0.5}
    on %Reject{}, do: {:error, :not_for_us}
    on %Skip{}, do: :skip
    on %BadField{}, do: {:upsert, %{nonexistent: 1}}
    on %WrongReturn{}, do: :wat
    on %BadInc{}, do: {:inc, :title, 1}
    on %UnknownInc{}, do: {:inc, :nope, 1}
    on %StringInc{}, do: {:inc, :open_count, "1"}
    on %KeyChange{}, do: {:upsert, %{list_id: "x"}}
  end

  @t0 ~U[2026-01-01 00:00:00.000000Z]

  setup do
    Repo.query!("""
    CREATE TEMP TABLE projection_summaries (
      list_id uuid PRIMARY KEY, owner_id varchar, title varchar,
      open_count bigint, done_count bigint, ratio double precision
    )
    """)

    %{list: UUID.uuid4()}
  end

  # A domain event struct, as the poller would deliver it.
  defp event(module, list, attrs \\ []),
    do: module |> struct(attrs) |> Map.put(:aggregate_id, list)

  defp type_name(module), do: module |> Module.split() |> Enum.join(".")

  # An event in the outbox, `n` seconds after the start of the (fake) day.
  defp store(module, list, n, payload \\ %{}) do
    id = UUID.uuid4()

    Repo.insert_all("domain_events", [
      %{
        id: Ecto.UUID.dump!(id),
        event_type: type_name(module),
        aggregate_id: list,
        aggregate_type: "My.List",
        payload: payload,
        occurred_at: DateTime.add(@t0, n, :second),
        inserted_at: DateTime.utc_now()
      }
    ])

    id
  end

  # Delivery records point at the stored event, so the event is stored first.
  defp deliver(module, list, attrs \\ []) do
    event = event(module, list, attrs)
    DDD.EventHandler.deliver(Summary, event, store(module, list, 0), Repo)
  end

  defp row(list) do
    {:ok, row} = Summary.get(list)
    row
  end

  defp start_poller do
    start_supervised!(
      {Poller, [repo: Repo, interval_ms: 600_000, backoff_ms: fn _ -> 0 end, max_retries: 1]}
    )

    Summary.subscribe()
    on_exit(&Summary.unsubscribe/0)
  end

  describe "applying events" do
    test "an upsert creates the row with the defaults, then sets only what it names", %{list: l} do
      assert :delivered = deliver(Created, l, owner_id: "ann", title: "Groceries")

      assert row(l) == %{
               list_id: l,
               owner_id: "ann",
               title: "Groceries",
               open_count: 0,
               done_count: 0,
               ratio: 0.0
             }

      assert :delivered = deliver(Added, l)
      assert :delivered = deliver(Created, l, owner_id: "bob", title: "Renamed")

      # The counters survive a later upsert of other fields.
      assert %{owner_id: "bob", title: "Renamed", open_count: 1} = row(l)
    end

    test "an increment creates the row when there is none, and adds to it otherwise", %{list: l} do
      assert :delivered = deliver(Added, l)
      assert %{open_count: 1, title: nil, done_count: 0} = row(l)

      assert :delivered = deliver(Added, l)
      assert :delivered = deliver(Done, l)
      assert %{open_count: 1, done_count: 1} = row(l)
      assert :delivered = deliver(Removed, l)
      assert %{open_count: 0} = row(l)
    end

    test "floats are incremented too", %{list: l} do
      assert :delivered = deliver(Rate, l)
      assert :delivered = deliver(Rate, l)
      assert %{ratio: 1.0} = row(l)
    end

    test "an update changes an existing row and ignores a missing one", %{list: l} do
      assert :delivered = deliver(Renamed, l, title: "nobody home")
      assert {:error, :not_found} = Summary.get(l)

      deliver(Created, l, title: "old")
      assert :delivered = deliver(Renamed, l, title: "new")
      assert %{title: "new"} = row(l)
    end

    test "delete removes the row, and a delete of nothing is fine", %{list: l} do
      deliver(Created, l, title: "x")
      assert :delivered = deliver(Closed, l)
      assert {:error, :not_found} = Summary.get(l)
      assert :delivered = deliver(Closed, l)
    end

    test "an upsert of nothing creates the row and leaves an existing one alone", %{list: l} do
      assert :delivered = deliver(Touch, l)
      assert %{title: nil, open_count: 0} = row(l)

      deliver(Created, l, title: "kept")
      assert :delivered = deliver(Touch, l)
      assert %{title: "kept"} = row(l)
    end

    test "a list of operations is applied in order", %{list: l} do
      assert :delivered = deliver(Both, l, title: "both")
      assert %{title: "both", open_count: 5} = row(l)
      assert :delivered = deliver(Both, l, title: "again")
      assert %{title: "again", open_count: 10} = row(l)
    end

    test ":skip and events without an `on` clause change nothing", %{list: l} do
      assert :delivered = deliver(Skip, l)
      assert :delivered = deliver(Ignored, l)
      assert {:error, :not_found} = Summary.get(l)
    end

    test "an error is a rejection like in any handler", %{list: l} do
      assert {:rejected, :not_for_us} = deliver(Reject, l)
      assert {:error, :not_found} = Summary.get(l)
    end

    test "an event without its key is a business error" do
      assert {:error, %DDD.Error{kind: :business, code: :missing_key}} =
               Summary.handle(event(Added, nil))
    end

    test "delivering the same event twice counts it once", %{list: l} do
      event = event(Added, l)
      id = store(Added, l, 0)

      assert :delivered = DDD.EventHandler.deliver(Summary, event, id, Repo)
      assert :skipped = DDD.EventHandler.deliver(Summary, event, id, Repo)
      assert %{open_count: 1} = row(l)
    end

    test "a bug in a projection is loud, not silently skipped", %{list: l} do
      assert_raise ArgumentError, ~r/no field :nonexistent to change/, fn ->
        Summary.handle(event(BadField, l))
      end

      assert_raise ArgumentError, ~r/returned :wat; expected/, fn ->
        Summary.handle(event(WrongReturn, l))
      end

      assert_raise ArgumentError, ~r/cannot increment :title \(:string\) by 1/, fn ->
        Summary.handle(event(BadInc, l))
      end

      assert_raise ArgumentError, ~r/has no field :nope/, fn ->
        Summary.handle(event(UnknownInc, l))
      end

      assert_raise ArgumentError, ~r/cannot increment :open_count \(:integer\) by "1"/, fn ->
        Summary.handle(event(StringInc, l))
      end

      assert_raise ArgumentError, ~r/the key can't be changed/, fn ->
        Summary.handle(event(KeyChange, l))
      end
    end

    test "through the outbox: handled in order, delivery recorded, event published", %{list: l} do
      start_poller()
      created = store(Created, l, 1, %{"owner_id" => "ann", "title" => "Groceries"})
      store(Added, l, 2)
      store(Added, l, 3)
      store(Done, l, 4)

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "deliver-#{inspect(ref)}",
        [:ddd, :handler, :deliver, :stop],
        fn _e, %{duration: d}, meta, _ -> send(parent, {ref, d, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("deliver-#{inspect(ref)}") end)

      assert {:ok, 4} = Poller.poll_now()

      assert %{title: "Groceries", owner_id: "ann", open_count: 1, done_count: 1} = row(l)

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM event_deliveries WHERE event_id = $1 AND handler = $2 AND outcome = 'delivered'",
                 [Ecto.UUID.dump!(created), inspect(Summary)]
               )

      assert_received {^ref, duration, %{handler: Summary, outcome: :delivered}}
      assert duration > 0
      assert %{pending: 0} = Summary.lag()
    end
  end

  describe "reading" do
    setup do
      ids =
        for {title, open, owner} <- [
              {"a", 3, "ann"},
              {"b", 1, "ann"},
              {"c", 0, "bob"},
              {"d", 2, "bob"}
            ] do
          id = UUID.uuid4()
          deliver(Created, id, owner_id: owner, title: title)
          for _ <- 1..open//1, do: deliver(Added, id)
          id
        end

      %{ids: ids}
    end

    test "get/1", %{ids: [first | _]} do
      assert {:ok, %{title: "a", open_count: 3}} = Summary.get(first)
      assert {:error, :not_found} = Summary.get(UUID.uuid4())
      assert {:error, :not_found} = Summary.get("not-a-uuid")
    end

    test "list, count, page and slice with filters and order" do
      titles = fn {:ok, rows} -> Enum.map(rows, & &1.title) end

      assert titles.(Summary.list(order: :title)) == ~w(a b c d)
      assert titles.(Summary.list(filter: [owner_id: "bob"], order: {:desc, :title})) == ~w(d c)
      assert titles.(Summary.list(filter: [open_count: {:gt, 0}], order: :title)) == ~w(a b d)
      assert {:ok, 3} = Summary.count(filter: [open_count: {:gt, 0}])

      assert {:ok,
              %DDD.Page{total_entries: 4, total_pages: 2, entries: [%{title: "c"}, %{title: "d"}]}} =
               Summary.page(order: :title, page: 2, page_size: 2)

      assert {:ok, %DDD.Slice{entries: [%{title: "a"}, %{title: "b"}], next_cursor: cursor}} =
               Summary.slice(order: :title, limit: 2)

      assert {:ok, %DDD.Slice{entries: [%{title: "c"}, %{title: "d"}], next_cursor: nil}} =
               Summary.slice(order: :title, limit: 2, after: cursor)

      assert {:error, %DDD.Error{code: :invalid_filter}} = Summary.list(filter: [nope: 1])
    end
  end

  describe "lag/0" do
    test "counts the events nobody has processed yet, and how long the oldest has waited", %{
      list: l
    } do
      assert %{pending: 0, oldest_pending_age_ms: 0} = Summary.lag()

      store(Added, l, 1)
      store(Added, l, 2)
      # Not one of this projection's events.
      store(Ping, l, 3)

      assert %{pending: 2, oldest_pending_age_ms: age} = Summary.lag()
      # The events are dated 2026-01-01.
      assert age > 1_000
    end

    test "an event the handler has processed is no longer pending", %{list: l} do
      id = store(Added, l, 1)
      store(Added, l, 2)
      assert %{pending: 2} = Summary.lag()

      Repo.insert_all("event_deliveries", [
        %{
          event_id: Ecto.UUID.dump!(id),
          handler: inspect(Summary),
          delivered_at: DateTime.utc_now()
        }
      ])

      assert %{pending: 1} = Summary.lag()
    end

    test "events that were discarded as dead letters are not pending", %{list: l} do
      id = store(Added, l, 1)
      assert %{pending: 1} = Summary.lag()

      Repo.query!("UPDATE domain_events SET resolution = 'discarded' WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

      assert %{pending: 0} = Summary.lag()
    end
  end

  describe "rebuild/0" do
    test "empties the table and replays the stored events in order", %{list: l} do
      other = UUID.uuid4()
      store(Created, l, 1, %{"owner_id" => "ann", "title" => "First"})
      store(Added, l, 2)
      store(Added, l, 3)
      store(Done, l, 4)
      store(Renamed, l, 5, %{"title" => "Second"})
      store(Added, other, 6)
      store(Ping, l, 7)

      # The table is wrong, and so is a row for a list that has no events.
      Repo.query!(
        "INSERT INTO projection_summaries (list_id, title, open_count) VALUES ($1, 'junk', 99)",
        [Ecto.UUID.dump!(UUID.uuid4())]
      )

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "rebuild-#{inspect(ref)}",
        [:ddd, :projection, :rebuild, :stop],
        fn _e, _m, meta, _ -> send(parent, {ref, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("rebuild-#{inspect(ref)}") end)

      assert {:ok, %{events: 6}} = Summary.rebuild()

      assert {:ok, 2} = Summary.count()
      assert %{title: "Second", owner_id: "ann", open_count: 1, done_count: 1} = row(l)
      assert %{open_count: 1} = row(other)
      assert %{pending: 0} = Summary.lag()
      assert_received {^ref, %{projection: Summary, events: 6}}
    end

    test "can be run again and gives the same table", %{list: l} do
      store(Added, l, 1)
      store(Added, l, 2)

      assert {:ok, %{events: 2}} = Summary.rebuild()
      assert {:ok, %{events: 2}} = Summary.rebuild()
      assert %{open_count: 2} = row(l)
    end

    test "replays more than one batch of events", %{list: l} do
      rows =
        for n <- 1..501 do
          %{
            id: Ecto.UUID.dump!(UUID.uuid4()),
            event_type: type_name(Added),
            aggregate_id: l,
            aggregate_type: "My.List",
            payload: %{},
            occurred_at: DateTime.add(@t0, n, :second),
            inserted_at: DateTime.utc_now()
          }
        end

      Repo.insert_all("domain_events", rows)

      assert {:ok, %{events: 501}} = Summary.rebuild()
      assert %{open_count: 501} = row(l)
    end

    test "a rejected event does not stop the rebuild, and discarded ones are not replayed", %{
      list: l
    } do
      store(Added, l, 1)
      store(Reject, l, 2)
      discarded = store(Added, l, 3)

      Repo.query!("UPDATE domain_events SET resolution = 'discarded' WHERE id = $1", [
        Ecto.UUID.dump!(discarded)
      ])

      store(Added, l, 4)

      capture_log(fn -> assert {:ok, %{events: 3}} = Summary.rebuild() end)
      assert %{open_count: 2} = row(l)
    end

    test "a failing event stops the rebuild with an error that says what to do", %{list: l} do
      store(Added, l, 1)
      store(BadField, l, 2)
      store(Added, l, 3)

      capture_log(fn ->
        assert {:error, %DDD.Error{kind: :infrastructure, code: :rebuild_failed} = error} =
                 Summary.rebuild()

        assert error.message =~ "the projection is partial"
        assert error.details.event_type == type_name(BadField)
      end)

      # What came before the failure was applied; what came after was not.
      assert %{open_count: 1} = row(l)
    end

    test "an event that cannot be rebuilt stops it too", %{list: l} do
      # A payload that is not an object cannot become an event struct.
      Repo.query!(
        "INSERT INTO domain_events (id, event_type, aggregate_id, aggregate_type, payload, " <>
          "occurred_at, inserted_at) VALUES (gen_random_uuid(), $1, $2, 'My.List', '[]'::jsonb, " <>
          "now(), now())",
        [type_name(Added), l]
      )

      assert {:error, %DDD.Error{code: :rebuild_failed, details: %{event_type: type}}} =
               Summary.rebuild()

      assert type == type_name(Added)
    end
  end

  describe "the projection as a model" do
    test "describes itself for the migration generator", %{} do
      assert Summary.__ddd_description__() == "One row per list"
      assert Summary.__ddd_kind__() == :projection
      assert Summary.__ddd_table__() == "projection_summaries"
      assert [{:list_id, :uuid, []}] = Summary.__ddd_identity__()
      assert Summary.schema() == Summary.Schema

      columns = DDD.Migration.columns(Summary)

      assert Enum.map(columns, & &1["name"]) ==
               ~w(list_id owner_id title open_count done_count ratio)

      assert %{"primary_key" => true, "type" => ":binary_id"} = hd(columns)
      assert DDD.Migration.default_table(Summary) == "projection_summaries"
    end

    @tag :tmp_dir
    test "mix vic.gen.migration can create its table", %{tmp_dir: dir} do
      assert {:ok, path} =
               DDD.Migration.generate(Summary,
                 snapshot_dir: Path.join(dir, "snapshots"),
                 migrations_path: Path.join(dir, "migrations"),
                 timestamp: "20300101000000"
               )

      content = File.read!(path)
      assert content =~ "create table(:projection_summaries, primary_key: false) do"
      assert content =~ "add :list_id, :binary_id, primary_key: true"
      assert content =~ "add :open_count, :integer"
    end

    test "the key must be one of the declared fields" do
      capture_io(:stderr, fn ->
        assert_raise CompileError, ~r/the key :nope is not a declared field/, fn ->
          Code.eval_string("""
          defmodule DDD.ProjectionTest.NoKey do
            use DDD.Projection, table: "x", key: :nope, events: []

            projection do
              field :id, :uuid
            end
          end
          """)
        end
      end)
    end

    test "a projection of only its key works" do
      Repo.query!("CREATE TEMP TABLE only_keys (id uuid PRIMARY KEY)")

      Code.eval_string("""
      defmodule DDD.ProjectionTest.OnlyKey do
        use DDD.Projection, table: "only_keys", key: :id, events: [DDD.ProjectionTest.Added]

        projection do
          field :id, :uuid
        end

        on %DDD.ProjectionTest.Added{}, do: {:upsert, %{}}
      end
      """)

      id = UUID.uuid4()
      only_key = Module.concat(DDD.ProjectionTest, OnlyKey)
      assert :ok = only_key.handle(event(Added, id))
      assert {:ok, %{id: ^id}} = only_key.get(id)
    end
  end

  describe "mix vic.projection.rebuild" do
    alias Mix.Tasks.Vic.Projection.Rebuild

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      :ok
    end

    defp shell_output(kind) do
      receive do
        {:mix_shell, ^kind, [message]} ->
          IO.iodata_to_binary(message) <> "\n" <> shell_output(kind)
      after
        0 -> ""
      end
    end

    test "rebuilds the named projections and says how many events it replayed", %{list: l} do
      store(Added, l, 1)
      store(Added, l, 2)

      assert :ok = Rebuild.run([inspect(Summary)])
      assert shell_output(:info) =~ "DDD.ProjectionTest.Summary: replayed 2 event(s)"
      assert %{open_count: 2} = row(l)
    end

    test "needs a projection" do
      assert_raise Mix.Error, ~r/usage: mix vic.projection.rebuild/, fn -> Rebuild.run([]) end
    end

    test "a module that is not a projection is reported and fails the task" do
      assert_raise Mix.Error, ~r/could not rebuild: Enum/, fn -> Rebuild.run(["Enum"]) end
      assert shell_output(:error) =~ "Enum is not a DDD.Projection"
    end

    test "a failed rebuild is reported, the others still run, and the task fails", %{list: l} do
      store(BadField, l, 1)

      assert_raise Mix.Error, ~r/could not rebuild: DDD.ProjectionTest.Summary/, fn ->
        Rebuild.run([inspect(Summary), "Enum"])
      end

      errors = shell_output(:error)
      assert errors =~ "the projection is partial"
      assert errors =~ "Enum is not a DDD.Projection"
    end
  end
end
