defmodule DDD.OptimisticLockingTest do
  use DDD.DataCase

  @moduletag :capture_log

  defmodule Renamed do
    use DDD.DomainEvent

    domain_event do
      field :text, :string
    end
  end

  defmodule Note do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :text, :string, required: true
    end

    defop rename(note, text) do
      note |> Map.put(:text, text) |> emit_event(Renamed.new(%{text: text}))
    end
  end

  defmodule NotePort do
    use DDD.Repository

    repo Note do
    end
  end

  defmodule PgNotes do
    use DDD.Repository.Ecto, port: NotePort, repo: DDD.TestRepo, table: "lock_notes"
  end

  defmodule MemNotes do
    use DDD.InMemoryRepository, port: NotePort
  end

  # Loads a note, runs the test's `:before_save` hook (which changes the stored row behind its
  # back), then renames and saves it: the shape of a lost race.
  defmodule Rename do
    use DDD.Command

    command do
      field :id, :string, required: true
      field :text, :string, required: true
    end

    @impl DDD.Command
    def execute(%{id: id, text: text}) do
      with {:ok, note} <- PgNotes.find_by_id(id) do
        if hook = Process.get(:before_save), do: hook.()
        with {:ok, note} <- Note.rename(note, text), do: PgNotes.save(note)
      end
    end
  end

  defmodule RenameWithRetry do
    use DDD.Command, retry_on_conflict: 2

    command do
      field :id, :string, required: true
      field :text, :string, required: true
    end

    @impl DDD.Command
    def execute(cmd), do: Rename.execute(cmd)
  end

  setup do
    DDD.TestRepo.query!("""
    CREATE TEMP TABLE lock_notes (
      id uuid PRIMARY KEY, text varchar,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    {:ok, note} = Note.new(text: "first")
    %{note: note}
  end

  defp stored_version(id) do
    %{rows: [[version]]} =
      DDD.TestRepo.query!("SELECT version FROM lock_notes WHERE id = $1", [Ecto.UUID.dump!(id)])

    version
  end

  defp events, do: DDD.TestRepo.query!("SELECT count(*) FROM domain_events").rows |> hd() |> hd()

  describe "the version" do
    test "starts at 0 and only the repository advances it", %{note: note} do
      assert note.version == 0
      assert {:ok, %{version: 0}} = Note.new(text: "x", version: 99)
      assert {:ok, %{version: 0}} = Note.update(note, text: "y", version: 99)
      assert {:ok, %{version: 0}} = Note.rename(note, "z")
    end

    test "every save advances it, in the row and in the returned aggregate", %{note: note} do
      assert {:ok, saved} = PgNotes.save(note)
      assert saved.version == 1
      assert stored_version(note.id) == 1

      {:ok, renamed} = Note.rename(saved, "second")
      assert {:ok, %{version: 2}} = PgNotes.save(renamed)
      assert {:ok, %{version: 2, text: "second"}} = PgNotes.find_by_id(note.id)
    end

    test "rows written before the column existed count as version 0", %{note: note} do
      {:ok, saved} = PgNotes.save(note)
      DDD.TestRepo.query!("UPDATE lock_notes SET version = 0")
      {:ok, loaded} = PgNotes.find_by_id(saved.id)
      assert loaded.version == 0
      assert {:ok, %{version: 1}} = PgNotes.save(loaded)
    end
  end

  describe "a lost race" do
    setup %{note: note} do
      {:ok, saved} = PgNotes.save(note)
      %{saved: saved}
    end

    test "the second save of a stale copy fails and changes nothing", %{saved: saved} do
      {:ok, mine} = Note.rename(saved, "mine")
      {:ok, theirs} = Note.rename(saved, "theirs")

      assert {:ok, _} = PgNotes.save(theirs)
      before = events()

      assert {:error, %DDD.Error{} = error} = PgNotes.save(mine)
      assert error.code == :stale_aggregate
      assert error.kind == :infrastructure
      assert error.entity == Note
      assert error.details == %{id: saved.id, expected_version: 1, actual_version: 2}

      assert {:ok, %{text: "theirs", version: 2}} = PgNotes.find_by_id(saved.id)
      # The stale save wrote no events either.
      assert events() == before
    end

    test "a fresh aggregate with an id that already exists is a conflict", %{saved: saved} do
      {:ok, duplicate} = Note.new(id: saved.id, text: "duplicate")
      assert {:error, %DDD.Error{code: :stale_aggregate}} = PgNotes.save(duplicate)
      assert {:ok, %{text: "first"}} = PgNotes.find_by_id(saved.id)
    end

    test "saving an aggregate whose row was deleted is a conflict", %{saved: saved} do
      :ok = PgNotes.delete(saved)

      assert {:error, %DDD.Error{code: :stale_aggregate, details: %{actual_version: nil}}} =
               PgNotes.save(saved)

      assert {:error, :not_found} = PgNotes.find_by_id(saved.id)
    end

    test "the UPDATE itself is guarded, not only the read before it", %{saved: saved} do
      # A concurrent save that commits between our read and our write cannot be staged on one
      # connection, so a trigger that swallows the UPDATE stands in for it: the statement
      # `UPDATE ... WHERE version = ?` then finds no row.
      DDD.TestRepo.query!("""
      CREATE FUNCTION lock_notes_swallow() RETURNS trigger AS
      $$ BEGIN RETURN NULL; END $$ LANGUAGE plpgsql
      """)

      DDD.TestRepo.query!("""
      CREATE TRIGGER lock_notes_swallow BEFORE UPDATE ON lock_notes
      FOR EACH ROW EXECUTE FUNCTION lock_notes_swallow()
      """)

      {:ok, mine} = Note.rename(saved, "mine")

      assert {:error, %DDD.Error{code: :stale_aggregate, details: %{expected_version: 1}}} =
               PgNotes.save(mine)

      assert {:ok, %{text: "first", version: 1}} = PgNotes.find_by_id(saved.id)
    end

    test "a conflict is reported on telemetry", %{saved: saved} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "conflict-#{inspect(ref)}",
        [:ddd, :repository, :conflict],
        fn _event, measurements, metadata, _ -> send(parent, {ref, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("conflict-#{inspect(ref)}") end)

      {:ok, theirs} = Note.rename(saved, "theirs")
      {:ok, mine} = Note.rename(saved, "mine")
      {:ok, _} = PgNotes.save(theirs)
      {:error, _} = PgNotes.save(mine)

      assert_receive {^ref, %{count: 1},
                      %{aggregate: Note, expected_version: 1, actual_version: 2}}
    end
  end

  describe "InMemoryRepository" do
    setup do
      start_supervised!(MemNotes)
      :ok
    end

    test "behaves the same way", %{note: note} do
      assert {:ok, %{version: 1} = saved} = MemNotes.save(note)
      {:ok, mine} = Note.rename(saved, "mine")
      {:ok, theirs} = Note.rename(saved, "theirs")

      assert {:ok, %{version: 2}} = MemNotes.save(theirs)

      assert {:error, %DDD.Error{code: :stale_aggregate, details: %{actual_version: 2}}} =
               MemNotes.save(mine)

      # A new aggregate whose id is taken, and one saved at a version that was never stored.
      {:ok, duplicate} = Note.new(id: note.id, text: "dup")
      assert {:error, %DDD.Error{code: :stale_aggregate}} = MemNotes.save(duplicate)

      {:ok, other} = Note.new(text: "other")

      assert {:error, %DDD.Error{code: :stale_aggregate}} =
               MemNotes.save(%{other | version: 4} |> DDD.Schema.seal())
    end
  end

  describe "retry_on_conflict" do
    setup %{note: note} do
      {:ok, saved} = PgNotes.save(note)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      lose = fn ->
        DDD.TestRepo.query!("UPDATE lock_notes SET version = version + 1")
      end

      # Loses the race on the first attempt only.
      Process.put(:before_save, fn ->
        if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0, do: lose.()
      end)

      # Every attempt loses.
      lose_always = fn ->
        Process.put(:before_save, fn ->
          Agent.update(counter, &(&1 + 1))
          lose.()
        end)
      end

      %{saved: saved, counter: counter, lose_always: lose_always}
    end

    test "without it the conflict is returned", %{saved: saved, counter: counter} do
      assert {:error, %DDD.Error{code: :stale_aggregate, context: %{command: Rename}}} =
               Rename.call(%{id: saved.id, text: "x"})

      assert Agent.get(counter, & &1) == 1
    end

    test "with it the command runs again on fresh data", %{saved: saved, counter: counter} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "retry-#{inspect(ref)}",
        [:ddd, :command, :retry],
        fn _event, measurements, metadata, _ -> send(parent, {ref, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("retry-#{inspect(ref)}") end)

      assert {:ok, %{text: "x"}} = RenameWithRetry.call(%{id: saved.id, text: "x"})
      assert Agent.get(counter, & &1) == 2
      assert_receive {^ref, %{attempt: 1}, %{command: RenameWithRetry}}
    end

    test "gives up after the configured retries", %{
      saved: saved,
      counter: counter,
      lose_always: lose_always
    } do
      lose_always.()

      assert {:error, %DDD.Error{code: :stale_aggregate}} =
               RenameWithRetry.call(%{id: saved.id, text: "x"})

      # The first attempt and two retries.
      assert Agent.get(counter, & &1) == 3
    end

    test "is not retried inside an outer transaction", %{
      saved: saved,
      counter: counter,
      lose_always: lose_always
    } do
      lose_always.()

      {:error, error} =
        DDD.TestRepo.transaction(fn ->
          with {:error, error} <- RenameWithRetry.call(%{id: saved.id, text: "x"}),
               do: DDD.TestRepo.rollback(error)
        end)

      assert error.code == :stale_aggregate
      assert Agent.get(counter, & &1) == 1
    end
  end
end
