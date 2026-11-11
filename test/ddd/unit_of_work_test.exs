defmodule DDD.UnitOfWorkTest do
  use DDD.DataCase

  @moduletag :capture_log

  alias DDD.UnitOfWork
  alias DDD.UnitOfWork.PendingChangesError

  defmodule Renamed do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :text, :string
    end
  end

  defmodule Note do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :text, :string, required: true
    end

    defop rename(note, text) do
      note |> Map.put(:text, text) |> emit_event(Renamed.new(%{text: text}))
    end

    # Changes the text without announcing it.
    defop retitle(note, text), do: Map.put(note, :text, text)
  end

  defmodule NotePort do
    @moduledoc false
    use DDD.Repository

    repo Note do
      find_by :text
    end
  end

  defmodule PgNotes do
    @moduledoc false
    use DDD.Repository.Ecto, port: NotePort, repo: DDD.TestRepo, table: "uow_notes"
  end

  # A port, as an application's repository ports are: `impl/0` gives the adapter.
  defmodule NotePortWithImpl do
    @moduledoc false
    def impl, do: DDD.UnitOfWorkTest.PgNotes
  end

  # A second table for the same aggregate, to see in what order tables are written.
  defmodule PgNotesB do
    @moduledoc false
    use DDD.Repository.Ecto, port: NotePort, repo: DDD.TestRepo, table: "uow_notes_b"
  end

  # A table whose `text` is unique, to see what breaking a constraint looks like.
  defmodule PgUnique do
    @moduledoc false
    use DDD.Repository.Ecto, port: NotePort, repo: DDD.TestRepo, table: "uow_unique_notes"
  end

  defmodule MemPort do
    @moduledoc false
    use DDD.Repository

    repo Note do
    end
  end

  defmodule MemNotes do
    @moduledoc false
    use DDD.InMemoryRepository, port: MemPort
  end

  defmodule Rename do
    @moduledoc false
    use DDD.Command

    command do
      field :id, :string, required: true
      field :text, :string, required: true
    end

    @impl DDD.Command
    def execute(%{id: id, text: text}) do
      with {:ok, note} <- PgNotes.find_by_id(id),
           {:ok, note} <- Note.rename(note, text),
           {:ok, note} <- PgNotes.save(note),
           # The same aggregate again: no query, and the version it will have.
           {:ok, again} <- PgNotes.find_by_id(id),
           do: {:ok, {note, again}}
    end
  end

  defmodule RenameThenSearch do
    @moduledoc false
    use DDD.Command

    command do
      field :id, :string, required: true
    end

    @impl DDD.Command
    def execute(%{id: id}) do
      with {:ok, note} <- PgNotes.find_by_id(id),
           {:ok, note} <- Note.rename(note, "changed"),
           {:ok, _} <- PgNotes.save(note) do
        {:ok, PgNotes.find_by_text("changed")}
      end
    end
  end

  # `loads:` reads the declared aggregates before `execute/1`, with one query.
  defmodule RenameMany do
    @moduledoc false
    use DDD.Command

    command do
      field :ids, {:array, :string}, required: true, loads: PgNotes
      field :text, :string, required: true
    end

    @impl DDD.Command
    def execute(%{ids: ids, text: text}) do
      if probe = Process.get(:probe), do: send(probe, {:executed, DDD.UnitOfWork.stats()})

      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
        with {:ok, note} <- PgNotes.find_by_id(id),
             {:ok, note} <- Note.rename(note, text),
             {:ok, note} <- PgNotes.save(note) do
          {:cont, {:ok, [note | acc]}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defmodule RenameTwo do
    @moduledoc false
    use DDD.Command

    command do
      field :first_id, :string, loads: PgNotes
      field :second_id, :string, loads: PgNotes
    end

    @impl DDD.Command
    def execute(%{first_id: a, second_id: b}) do
      {:ok, for(id <- [a, b], id != nil, do: PgNotes.find_by_id(id))}
    end
  end

  defmodule MemRename do
    @moduledoc false
    use DDD.Command, transaction: false

    command do
      field :id, :string, required: true, loads: DDD.UnitOfWorkTest.MemNotes
    end

    @impl DDD.Command
    def execute(%{id: id}) do
      with {:ok, note} <- DDD.UnitOfWorkTest.MemNotes.find_by_id(id),
           do: {:ok, {note, DDD.UnitOfWork.stats()}}
    end
  end

  setup do
    Repo.query!("""
    CREATE TEMP TABLE uow_notes (
      id uuid PRIMARY KEY, text varchar,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    Repo.query!("""
    CREATE TEMP TABLE uow_notes_b (
      id uuid PRIMARY KEY, text varchar,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    Repo.query!("""
    CREATE TEMP TABLE uow_unique_notes (
      id uuid PRIMARY KEY, text varchar UNIQUE,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    {:ok, note} = Note.new(text: "first")
    {:ok, saved} = PgNotes.save(note)
    %{saved: saved}
  end

  defp row(id) do
    Repo.query!("SELECT text, version FROM uow_notes WHERE id = $1", [Ecto.UUID.dump!(id)]).rows
  end

  defp events, do: Repo.query!("SELECT count(*) FROM domain_events").rows |> hd() |> hd()

  # How many statements read or write the notes table while `fun` runs.
  defp queries_on_notes(fun) do
    parent = self()
    id = "uow-#{inspect(make_ref())}"

    :telemetry.attach(
      id,
      [:ddd, :test_repo, :query],
      fn _, _, %{query: query}, _ ->
        if query =~ "uow_notes", do: send(parent, {:query, query})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    {result, drain_queries([])}
  end

  defp drain_queries(acc) do
    receive do
      {:query, query} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "outside a unit of work" do
    test "nothing changes: save writes at once and find_by_id always reads", %{saved: saved} do
      refute UnitOfWork.open?()
      assert row(saved.id) == [["first", 1]]

      {:ok, renamed} = Note.rename(saved, "second")
      assert {:ok, %{version: 2}} = PgNotes.save(renamed)
      assert row(saved.id) == [["second", 2]]

      {_, queries} =
        queries_on_notes(fn ->
          PgNotes.find_by_id(saved.id)
          PgNotes.find_by_id(saved.id)
        end)

      assert length(queries) == 2
    end
  end

  describe "inside a unit of work" do
    test "an aggregate is loaded once, and the second read costs no query", %{saved: saved} do
      {{:ok, {first, second}}, queries} =
        queries_on_notes(fn ->
          UnitOfWork.run(fn ->
            {:ok, a} = PgNotes.find_by_id(saved.id)
            {:ok, b} = PgNotes.find_by_id(saved.id)
            {:ok, {a, b}}
          end)
        end)

      assert first == second
      assert length(queries) == 1
    end

    test "save writes nothing until the unit of work ends", %{saved: saved} do
      UnitOfWork.run(fn ->
        {:ok, note} = PgNotes.find_by_id(saved.id)
        {:ok, note} = Note.rename(note, "later")
        assert {:ok, %{version: 2}} = PgNotes.save(note)

        assert row(saved.id) == [["first", 1]]
        assert events() == 0
        assert UnitOfWork.pending?()
        {:ok, :done}
      end)

      assert row(saved.id) == [["later", 2]]
      assert events() == 1
      refute UnitOfWork.open?()
    end

    test "a read after a save sees the saved aggregate with its new version", %{saved: saved} do
      assert {:ok, {note, again}} = Rename.call(%{id: saved.id, text: "renamed"})

      assert note.version == 2
      assert again == note
      assert again.text == "renamed"
      assert row(saved.id) == [["renamed", 2]]
    end

    test "saving the same aggregate twice writes it once, with all its events", %{saved: saved} do
      {{:ok, _}, queries} =
        queries_on_notes(fn ->
          UnitOfWork.run(fn ->
            {:ok, note} = PgNotes.find_by_id(saved.id)
            {:ok, note} = Note.rename(note, "one")
            {:ok, note} = PgNotes.save(note)
            {:ok, note} = Note.rename(note, "two")
            assert {:ok, %{version: 2}} = PgNotes.save(note)
            {:ok, :done}
          end)
        end)

      assert row(saved.id) == [["two", 2]]
      assert events() == 2
      assert Enum.count(queries, &(&1 =~ "UPDATE")) == 1
    end

    test "an aggregate that was loaded and not changed is not written", %{saved: saved} do
      {{:ok, _}, queries} =
        queries_on_notes(fn ->
          UnitOfWork.run(fn ->
            {:ok, note} = PgNotes.find_by_id(saved.id)
            {:ok, _} = PgNotes.save(note)
            {:ok, :done}
          end)
        end)

      assert row(saved.id) == [["first", 1]]
      refute Enum.any?(queries, &(&1 =~ "UPDATE"))
    end

    test "an aggregate that changed without an event is written", %{saved: saved} do
      UnitOfWork.run(fn ->
        {:ok, note} = PgNotes.find_by_id(saved.id)
        {:ok, note} = Note.retitle(note, "quiet")
        {:ok, _} = PgNotes.save(note)
        {:ok, :done}
      end)

      assert row(saved.id) == [["quiet", 2]]
      assert events() == 0
    end

    test "a new aggregate is written at version 1", %{saved: _} do
      {:ok, note} = Note.new(text: "new")

      assert {:ok, %{version: 1} = saved} =
               UnitOfWork.run(fn -> PgNotes.save(note) end)

      assert row(note.id) == [["new", 1]]
      assert saved.id == note.id
    end

    test "a deleted aggregate is gone for the rest of the unit and removed at the end",
         %{saved: saved} do
      UnitOfWork.run(fn ->
        {:ok, note} = PgNotes.find_by_id(saved.id)
        assert :ok = PgNotes.delete(note)

        assert {:error, :not_found} = PgNotes.find_by_id(saved.id)
        assert row(saved.id) == [["first", 1]]
        {:ok, :done}
      end)

      assert row(saved.id) == []
    end

    test "an aggregate created and deleted in the same unit never reaches the database" do
      {:ok, note} = Note.new(text: "ghost")

      {{:ok, _}, queries} =
        queries_on_notes(fn ->
          UnitOfWork.run(fn ->
            {:ok, saved} = PgNotes.save(note)
            :ok = PgNotes.delete(saved)
            {:ok, :done}
          end)
        end)

      assert row(note.id) == []
      assert queries == []
    end

    test "nothing is written when the unit of work returns an error", %{saved: saved} do
      assert {:error, :nope} =
               UnitOfWork.run(fn ->
                 {:ok, note} = PgNotes.find_by_id(saved.id)
                 {:ok, note} = Note.rename(note, "never")
                 {:ok, _} = PgNotes.save(note)
                 {:error, :nope}
               end)

      assert row(saved.id) == [["first", 1]]
      assert events() == 0
      refute UnitOfWork.open?()
    end

    test "nothing is written and the state is dropped when it raises", %{saved: saved} do
      assert_raise RuntimeError, "boom", fn ->
        UnitOfWork.run(fn ->
          {:ok, note} = PgNotes.find_by_id(saved.id)
          {:ok, note} = Note.rename(note, "never")
          {:ok, _} = PgNotes.save(note)
          raise "boom"
        end)
      end

      assert row(saved.id) == [["first", 1]]
      refute UnitOfWork.open?()
    end

    test "a nested run joins the outer one, which writes", %{saved: saved} do
      UnitOfWork.run(fn ->
        UnitOfWork.run(fn ->
          {:ok, note} = PgNotes.find_by_id(saved.id)
          {:ok, note} = Note.rename(note, "inner")
          {:ok, _} = PgNotes.save(note)
          {:ok, :inner}
        end)

        assert row(saved.id) == [["first", 1]]
        {:ok, :outer}
      end)

      assert row(saved.id) == [["inner", 2]]
    end

    test "stats count loads, identity-map hits and recorded changes", %{saved: saved} do
      assert UnitOfWork.stats() == nil

      UnitOfWork.run(fn ->
        {:ok, note} = PgNotes.find_by_id(saved.id)
        {:ok, _} = PgNotes.find_by_id(saved.id)
        {:ok, note} = Note.rename(note, "x")
        {:ok, _} = PgNotes.save(note)

        assert UnitOfWork.stats() == %{loaded: 1, hits: 1, saved: 1, deleted: 0}
        {:ok, :done}
      end)
    end

    test "an aggregate that was not produced by the framework is refused", %{saved: saved} do
      forged = %{saved | text: "tampered"}

      assert {:error, %DDD.Error{code: :unsealed}} =
               UnitOfWork.run(fn -> PgNotes.save(forged) end)
    end

    test "saving an older copy than the one the unit holds is a conflict", %{saved: saved} do
      # A copy loaded earlier, outside the unit, and then overtaken by a save.
      {:ok, old} = Note.rename(saved, "old copy")
      {:ok, newer} = Note.retitle(saved, "newer")
      {:ok, _} = PgNotes.save(newer)

      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 {:ok, %{version: 2}} = PgNotes.find_by_id(saved.id)
                 PgNotes.save(old)
               end)

      assert error.details == %{id: saved.id, expected_version: 1, actual_version: 3}
      assert row(saved.id) == [["newer", 2]]
    end
  end

  describe "reads that are not by id" do
    test "raise once something is saved or deleted", %{saved: saved} do
      for query <- [
            fn -> PgNotes.find_by_text("x") end,
            fn -> PgNotes.list() end,
            fn -> PgNotes.page() end,
            fn -> PgNotes.slice() end,
            fn -> PgNotes.count() end
          ] do
        assert_raise PendingChangesError,
                     ~r/does not have this command's unwritten changes/,
                     fn ->
                       UnitOfWork.run(fn ->
                         {:ok, note} = PgNotes.find_by_id(saved.id)
                         {:ok, note} = Note.rename(note, "pending")
                         {:ok, _} = PgNotes.save(note)
                         query.()
                       end)
                     end
      end

      assert row(saved.id) == [["first", 1]]
    end

    test "are fine before the first save, and a by-id read is always fine", %{saved: saved} do
      assert {:ok, {1, ["first"]}} =
               UnitOfWork.run(fn ->
                 assert {:ok, 1} = PgNotes.count()
                 [found] = PgNotes.find_by_text("first")
                 {:ok, note} = Note.rename(found, "later")
                 {:ok, _} = PgNotes.save(note)

                 assert {:ok, _} = PgNotes.find_by_id(saved.id)
                 {:ok, {1, [found.text]}}
               end)
    end

    test "a command that searches after saving fails with the explanation", %{saved: saved} do
      assert_raise PendingChangesError, ~r/find_by_text/, fn ->
        RenameThenSearch.call(%{id: saved.id})
      end

      assert row(saved.id) == [["first", 1]]
    end
  end

  describe "a lost race" do
    test "fails the unit of work with :stale_aggregate and writes nothing", %{saved: saved} do
      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 {:ok, note} = PgNotes.find_by_id(saved.id)

                 # Someone else commits between our read and our write.
                 Repo.query!("UPDATE uow_notes SET text = 'theirs', version = version + 1")

                 {:ok, note} = Note.rename(note, "mine")
                 {:ok, _} = PgNotes.save(note)
                 {:ok, :done}
               end)

      assert error.entity == Note
      assert row(saved.id) == [["theirs", 2]]
      assert events() == 0
    end

    test "a command with retry_on_conflict re-runs it on fresh data", %{saved: saved} do
      defmodule RetriedRename do
        @moduledoc false
        use DDD.Command, retry_on_conflict: 2

        command do
          field :id, :string, required: true
        end

        @impl DDD.Command
        def execute(%{id: id}) do
          {:ok, note} = DDD.UnitOfWorkTest.PgNotes.find_by_id(id)

          # Lose the race on the first attempt only.
          if Process.get(:lost) == nil do
            Process.put(:lost, true)
            DDD.TestRepo.query!("UPDATE uow_notes SET text = 'theirs', version = version + 1")
          end

          with {:ok, note} <- DDD.UnitOfWorkTest.Note.rename(note, "mine"),
               do: DDD.UnitOfWorkTest.PgNotes.save(note)
        end
      end

      ref = make_ref()
      parent = self()
      handler = "retry-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:ddd, :command, :retry],
        fn _, measurements, _, _ -> send(parent, {ref, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # (The test shares one connection, so the competing update is rolled back with the failed
      # attempt; what matters here is that the conflict at the flush was retried.)
      assert {:ok, %{text: "mine"}} = RetriedRename.call(%{id: saved.id})
      assert_receive {^ref, %{attempt: 1}}
      assert [["mine", _]] = row(saved.id)
    end
  end

  # Every statement the repo runs while `fun` does.
  defp all_queries(fun) do
    parent = self()
    id = "all-#{inspect(make_ref())}"

    :telemetry.attach(
      id,
      [:ddd, :test_repo, :query],
      fn _, _, %{query: query}, _ -> send(parent, {:query, query}) end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    {result, drain_queries([])}
  end

  defp count_of(queries, pattern), do: Enum.count(queries, &(&1 =~ pattern))

  defp saved_notes(n) do
    for i <- 1..n do
      {:ok, note} = Note.new(text: "note #{i}")
      {:ok, saved} = PgNotes.save(note)
      saved
    end
  end

  defp rename_all(notes, suffix) do
    for note <- notes do
      {:ok, loaded} = PgNotes.find_by_id(note.id)
      {:ok, renamed} = Note.rename(loaded, loaded.text <> suffix)
      {:ok, _} = PgNotes.save(renamed)
    end
  end

  describe "batched writes" do
    test "twenty changed aggregates are one UPDATE and one INSERT of their events" do
      notes = saved_notes(20)

      {{:ok, _}, queries} =
        all_queries(fn ->
          UnitOfWork.run(fn ->
            rename_all(notes, "!")
            {:ok, :done}
          end)
        end)

      assert count_of(queries, ~s(UPDATE "uow_notes")) == 1
      assert count_of(queries, ~s(INSERT INTO "domain_events")) == 1
      assert events() == 20

      for note <- notes, do: assert(row(note.id) == [[note.text <> "!", 2]])
    end

    test "twenty new aggregates are one INSERT" do
      new =
        for i <- 1..20 do
          {:ok, note} = Note.new(text: "new #{i}")
          note
        end

      {{:ok, _}, queries} =
        all_queries(fn ->
          UnitOfWork.run(fn ->
            for note <- new, do: {:ok, _} = PgNotes.save(note)
            {:ok, :done}
          end)
        end)

      assert count_of(queries, ~s(INSERT INTO "uow_notes")) == 1

      for note <- new, do: assert(row(note.id) == [[note.text, 1]])
    end

    test "inserts, updates, deletes and version checks are one statement each" do
      [updated, deleted, checked] = saved_notes(3)
      {:ok, created} = Note.new(text: "created")

      {{:ok, _}, queries} =
        all_queries(fn ->
          UnitOfWork.run(fn ->
            {:ok, a} = PgNotes.find_by_id(updated.id)
            {:ok, a} = Note.retitle(a, "updated")
            {:ok, _} = PgNotes.save(a)

            {:ok, b} = PgNotes.find_by_id(deleted.id)
            :ok = PgNotes.delete(b)

            # An operation that announces something and changes nothing it stores.
            {:ok, c} = PgNotes.find_by_id(checked.id)
            {:ok, c} = Note.rename(c, c.text)
            {:ok, _} = PgNotes.save(c)

            {:ok, _} = PgNotes.save(created)
            {:ok, :done}
          end)
        end)

      assert count_of(queries, ~s(INSERT INTO "uow_notes")) == 1
      assert count_of(queries, ~s(UPDATE "uow_notes")) == 1
      assert count_of(queries, ~s(DELETE FROM "uow_notes")) == 1
      assert count_of(queries, ~s(INSERT INTO "domain_events")) == 1

      assert row(updated.id) == [["updated", 2]]
      assert row(deleted.id) == []
      assert row(created.id) == [["created", 1]]
      # Only its events were written: the row stays at the version it had.
      assert row(checked.id) == [[checked.text, 1]]
      assert events() == 1
    end

    test "an aggregate that only emitted events is not rewritten, but its version is checked",
         %{saved: saved} do
      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 {:ok, note} = PgNotes.find_by_id(saved.id)
                 {:ok, note} = Note.rename(note, note.text)
                 {:ok, _} = PgNotes.save(note)

                 Repo.query!("UPDATE uow_notes SET version = version + 1")
                 {:ok, :done}
               end)

      assert error.details == %{
               id: saved.id,
               expected_version: 1,
               actual_version: 2,
               conflicts: [%{id: saved.id, expected_version: 1, actual_version: 2}]
             }

      assert events() == 0
    end

    test "the version check of an event-only aggregate holds the row until the commit",
         %{saved: saved} do
      {{:ok, _}, queries} =
        queries_on_notes(fn ->
          UnitOfWork.run(fn ->
            {:ok, note} = PgNotes.find_by_id(saved.id)
            {:ok, note} = Note.rename(note, note.text)
            {:ok, _} = PgNotes.save(note)
            {:ok, :done}
          end)
        end)

      # The read for the load has no lock; the check that follows does.
      assert [_load, check] = Enum.filter(queries, &(&1 =~ "SELECT"))
      assert check =~ "FOR SHARE"
    end

    test "breaking a unique index is a :persistence_failed, not a lost race" do
      {:ok, a} = Note.new(text: "same")
      {:ok, b} = Note.new(text: "same")

      assert {:error, %DDD.Error{code: :persistence_failed} = error} =
               UnitOfWork.run(fn ->
                 {:ok, _} = PgUnique.save(a)
                 {:ok, _} = PgUnique.save(b)
                 {:ok, :done}
               end)

      assert %{kind: :unique, constraint: "uow_unique_notes_text_key"} = error.details
      assert Repo.query!("SELECT count(*) FROM uow_unique_notes").rows == [[0]]
    end

    test "an existing key is still a lost race, not a constraint error" do
      {:ok, a} = Note.new(text: "one")
      {:ok, _} = PgUnique.save(a)
      {:ok, again} = Note.new(id: a.id, text: "two")

      assert {:error, %DDD.Error{code: :stale_aggregate}} =
               UnitOfWork.run(fn ->
                 {:ok, _} = PgUnique.save(again)
                 {:ok, :done}
               end)
    end

    test "everything that lost the race is reported together, and nothing is written" do
      [a, b, c] = saved_notes(3)

      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 rename_all([a, b, c], "!")

                 Repo.query!("UPDATE uow_notes SET version = version + 1 WHERE id != $1", [
                   Ecto.UUID.dump!(c.id)
                 ])

                 {:ok, :done}
               end)

      lost = error.details.conflicts |> Enum.map(& &1.id) |> Enum.sort()
      assert lost == Enum.sort([a.id, b.id])

      assert Enum.all?(
               error.details.conflicts,
               &(&1.expected_version == 1 and &1.actual_version == 2)
             )

      # The usual fields describe the first of them.
      assert error.details.id == hd(error.details.conflicts).id

      assert row(c.id) == [[c.text, 1]]
      assert events() == 0
    end

    test "a new aggregate whose id already exists is a conflict", %{saved: saved} do
      {:ok, duplicate} = Note.new(id: saved.id, text: "duplicate")

      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn -> PgNotes.save(duplicate) end)

      assert error.details.expected_version == 0
      assert error.details.actual_version == 1
      assert row(saved.id) == [["first", 1]]
    end

    test "a delete is guarded by the version, like a save", %{saved: saved} do
      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 {:ok, note} = PgNotes.find_by_id(saved.id)
                 Repo.query!("UPDATE uow_notes SET version = version + 1")
                 PgNotes.delete(note)
                 {:ok, :done}
               end)

      assert {error.details.expected_version, error.details.actual_version} == {1, 2}
      assert row(saved.id) == [["first", 2]]
    end

    test "deleting a row that is already gone is a conflict too", %{saved: saved} do
      assert {:error, %DDD.Error{code: :stale_aggregate} = error} =
               UnitOfWork.run(fn ->
                 {:ok, note} = PgNotes.find_by_id(saved.id)
                 Repo.query!("DELETE FROM uow_notes")
                 PgNotes.delete(note)
                 {:ok, :done}
               end)

      assert error.details.actual_version == nil
    end

    test "the writes land together even without a command's transaction", %{saved: saved} do
      {:ok, fresh} = Note.new(text: "fresh")

      assert {:error, %DDD.Error{code: :stale_aggregate}} =
               UnitOfWork.run(fn ->
                 {:ok, _} = PgNotes.save(fresh)
                 {:ok, note} = PgNotes.find_by_id(saved.id)
                 {:ok, note} = Note.retitle(note, "mine")
                 {:ok, _} = PgNotes.save(note)

                 Repo.query!("UPDATE uow_notes SET version = version + 1 WHERE id = $1", [
                   Ecto.UUID.dump!(saved.id)
                 ])

                 {:ok, :done}
               end)

      # The insert that came before the conflict was rolled back with it.
      assert row(fresh.id) == []
      assert row(saved.id) == [["first", 2]]
    end

    test "the flush reports what it did" do
      notes = saved_notes(4)
      ref = make_ref()
      parent = self()
      handler = "flush-#{inspect(ref)}"

      :telemetry.attach_many(
        handler,
        [[:ddd, :unit_of_work, :flush, :start], [:ddd, :unit_of_work, :flush, :stop]],
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} =
        UnitOfWork.run(fn ->
          rename_all(notes, "?")
          {:ok, loaded} = PgNotes.find_by_id(hd(notes).id)
          assert loaded.text =~ "?"
          {:ok, :done}
        end)

      assert_received {^ref, [:ddd, :unit_of_work, :flush, :start], _, %{adapters: [PgNotes]}}

      assert_received {^ref, [:ddd, :unit_of_work, :flush, :stop], measurements, %{result: :ok}}

      assert %{updated: 4, inserted: 0, deleted: 0, checked: 0, events: 4, loaded: 4, hits: 1} =
               measurements

      # One UPDATE and one INSERT of the events.
      assert measurements.statements == 2
      assert is_integer(measurements.duration)
    end

    test "a failed flush is reported as an error result" do
      [note] = saved_notes(1)
      ref = make_ref()
      parent = self()
      handler = "flush-fail-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:ddd, :unit_of_work, :flush, :stop],
        fn _, _, metadata, _ -> send(parent, {ref, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:error, _} =
        UnitOfWork.run(fn ->
          rename_all([note], "!")
          Repo.query!("UPDATE uow_notes SET version = version + 1")
          {:ok, :done}
        end)

      assert_received {^ref, %{result: :error}}
    end

    test "a database without batched writes is written one aggregate at a time" do
      defmodule OneAtATime do
        @moduledoc false
        @behaviour DDD.Dialect
        defdelegate lock_for_claim(query), to: DDD.Dialect.Postgres
        defdelegate now(repo), to: DDD.Dialect.Postgres
        defdelegate read_only(repo, fun), to: DDD.Dialect.Postgres
        defdelegate columns(repo, table), to: DDD.Dialect.Postgres
      end

      Application.put_env(:vicander, :dialect, OneAtATime)
      on_exit(fn -> Application.delete_env(:vicander, :dialect) end)

      refute DDD.Dialect.batch?(OneAtATime)
      notes = saved_notes(3)

      {{:ok, _}, queries} =
        all_queries(fn ->
          UnitOfWork.run(fn ->
            rename_all(notes, "!")
            {:ok, :done}
          end)
        end)

      assert count_of(queries, ~s(UPDATE "uow_notes")) == 3
      for note <- notes, do: assert(row(note.id) == [[note.text <> "!", 2]])
      assert events() == 3
    end
  end

  # Every statement with its parameters, in the order it ran.
  defp all_statements(fun) do
    parent = self()
    id = "stmts-#{inspect(make_ref())}"

    :telemetry.attach(
      id,
      [:ddd, :test_repo, :query],
      fn _, _, %{query: query, params: params}, _ ->
        send(parent, {:statement, query, params})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    {result, collect_statements([])}
  end

  defp collect_statements(acc) do
    receive do
      {:statement, query, params} -> collect_statements([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Rename every note of `notes`, in that order, in `repository`.
  def rename_in(repository, notes) do
    for note <- notes do
      {:ok, loaded} = repository.find_by_id(note.id)
      {:ok, renamed} = Note.rename(loaded, loaded.text <> "!")
      {:ok, _} = repository.save(renamed)
    end
  end

  describe "flush_order: :sorted" do
    test "locks the rows it changes in key order, whatever order they were saved in" do
      notes = saved_notes(5)
      reversed = Enum.sort_by(notes, & &1.id, :desc)

      {{:ok, _}, statements} =
        all_statements(fn ->
          UnitOfWork.run(
            fn ->
              rename_in(PgNotes, reversed)
              {:ok, :done}
            end,
            flush_order: :sorted
          )
        end)

      assert [{_query, [locked]}] =
               Enum.filter(statements, fn {query, _} -> query =~ "FOR UPDATE" end)

      assert locked == locked |> Enum.sort()
      assert length(locked) == 5

      for note <- notes, do: assert(row(note.id) == [[note.text <> "!", 2]])
    end

    test "by default takes no locks of its own and writes in the order it was given" do
      notes = saved_notes(3)

      {{:ok, _}, statements} =
        all_statements(fn ->
          UnitOfWork.run(fn ->
            rename_in(PgNotes, notes)
            {:ok, :done}
          end)
        end)

      refute Enum.any?(statements, fn {query, _} -> query =~ "FOR UPDATE" end)
    end

    test "writes the tables in name order, whatever order they were saved in" do
      {:ok, a} = Note.new(text: "in a")
      {:ok, b} = Note.new(text: "in b")
      {:ok, a} = PgNotes.save(a)
      {:ok, b} = PgNotesB.save(b)

      updates = fn flush_order ->
        {{:ok, _}, statements} =
          all_statements(fn ->
            UnitOfWork.run(
              fn ->
                # The table named later is saved first.
                rename_in(PgNotesB, [b])
                rename_in(PgNotes, [a])
                {:ok, :done}
              end,
              flush_order: flush_order
            )
          end)

        for {query, _} <- statements, query =~ "UPDATE \"uow_notes", do: query
      end

      assert [first, second] = updates.(:registration)
      assert first =~ ~s(UPDATE "uow_notes_b")
      assert second =~ ~s(UPDATE "uow_notes")

      assert [first, second] = updates.(:sorted)
      assert first =~ ~s(UPDATE "uow_notes" AS)
      assert second =~ ~s(UPDATE "uow_notes_b")
    end

    test "a command asks for it with an option, and it counts in the flush's statements" do
      defmodule SortedRename do
        @moduledoc false
        use DDD.Command, flush_order: :sorted

        command do
          field :ids, {:array, :string}, required: true, loads: DDD.UnitOfWorkTest.PgNotes
        end

        @impl DDD.Command
        def execute(%{ids: ids}) do
          {:ok,
           DDD.UnitOfWorkTest.rename_in(DDD.UnitOfWorkTest.PgNotes, Enum.map(ids, &%{id: &1}))}
        end
      end

      assert SortedRename.__cmd_flush_order__() == :sorted
      assert Rename.__cmd_flush_order__() == :registration

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "sorted-#{inspect(ref)}",
        [:ddd, :unit_of_work, :flush, :stop],
        fn _, measurements, metadata, _ -> send(parent, {ref, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("sorted-#{inspect(ref)}") end)

      ids = saved_notes(4) |> Enum.map(& &1.id)
      assert {:ok, _} = SortedRename.call(%{ids: ids})

      # The update, the lock before it, and the events.
      assert_received {^ref, %{updated: 4, statements: 3}, %{flush_order: :sorted}}
    end

    test "a unit of work that joins another and asks for it makes the whole of it sorted" do
      notes = saved_notes(3)

      {{:ok, _}, statements} =
        all_statements(fn ->
          UnitOfWork.run(fn ->
            UnitOfWork.run(
              fn ->
                rename_in(PgNotes, notes)
                {:ok, :inner}
              end,
              flush_order: :sorted
            )
          end)
        end)

      assert Enum.any?(statements, fn {query, _} -> query =~ "FOR UPDATE" end)
    end

    test "is :registration or :sorted" do
      assert_raise ArgumentError,
                   ~r/`flush_order:` is :registration or :sorted, got :random/,
                   fn ->
                     Code.eval_string("""
                     defmodule DDD.UnitOfWorkTest.BadOrder do
                       use DDD.Command, flush_order: :random
                       command do
                         field :id, :string
                       end
                       def execute(_), do: {:ok, 1}
                     end
                     """)
                   end
    end
  end

  describe "deadlocks" do
    defp deadlock do
      %Postgrex.Error{postgres: %{code: :deadlock_detected, message: "deadlock detected"}}
    end

    test "Postgres says a deadlock and a serialization failure are worth retrying, and nothing else" do
      assert DDD.Dialect.Postgres.retryable?(deadlock())

      assert DDD.Dialect.Postgres.retryable?(%Postgrex.Error{
               postgres: %{code: :serialization_failure, message: "x"}
             })

      refute DDD.Dialect.Postgres.retryable?(%Postgrex.Error{
               postgres: %{code: :unique_violation, message: "x"}
             })

      refute DDD.Dialect.Postgres.retryable?(%RuntimeError{message: "x"})
      assert DDD.Dialect.retryable?(Repo, deadlock())
      refute DDD.Dialect.retryable?(Repo, %RuntimeError{message: "x"})
    end

    test "a command whose transaction the database aborts fails with :deadlock_detected" do
      defmodule Aborted do
        @moduledoc false
        use DDD.Command

        command do
          field :id, :string
        end

        @impl DDD.Command
        def execute(_) do
          raise %Postgrex.Error{
            postgres: %{code: :deadlock_detected, message: "deadlock detected"}
          }
        end
      end

      assert {:error, %DDD.Error{} = error} = Aborted.call(%{})
      assert error.code == :deadlock_detected
      assert error.kind == :infrastructure
      assert error.context == %{command: Aborted}
      assert error.details.reason =~ "deadlock detected"
    end

    test "retry_on_conflict runs it again" do
      defmodule AbortedOnce do
        @moduledoc false
        use DDD.Command, retry_on_conflict: 2

        command do
          field :id, :string
        end

        @impl DDD.Command
        def execute(_) do
          attempts = Process.get(:attempts, 0) + 1
          Process.put(:attempts, attempts)

          if attempts == 1,
            do:
              raise(%Postgrex.Error{
                postgres: %{code: :deadlock_detected, message: "deadlock detected"}
              })

          {:ok, attempts}
        end
      end

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "abort-#{inspect(ref)}",
        [:ddd, :command, :retry],
        fn _, measurements, _, _ -> send(parent, {ref, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("abort-#{inspect(ref)}") end)

      assert {:ok, 2} = AbortedOnce.call(%{})
      assert_received {^ref, %{attempt: 1}}
    end

    test "another database error is still raised" do
      defmodule Broken do
        @moduledoc false
        use DDD.Command, retry_on_conflict: 2

        command do
          field :id, :string
        end

        @impl DDD.Command
        def execute(_) do
          raise %Postgrex.Error{
            postgres: %{
              code: :unique_violation,
              message: "duplicate",
              severity: "ERROR",
              pg_code: "23505"
            }
          }
        end
      end

      assert_raise Postgrex.Error, fn -> Broken.call(%{}) end
    end

    test "a deadlock while the unit of work writes is reported, and retried", %{saved: saved} do
      defmodule DeadlockingDialect do
        @moduledoc false
        @behaviour DDD.Dialect
        defdelegate lock_for_claim(query), to: DDD.Dialect.Postgres
        defdelegate now(repo), to: DDD.Dialect.Postgres
        defdelegate read_only(repo, fun), to: DDD.Dialect.Postgres
        defdelegate columns(repo, table), to: DDD.Dialect.Postgres
        defdelegate insert_new(repo, schema, pk, rows), to: DDD.Dialect.Postgres
        defdelegate delete_versioned(repo, schema, pk, rows), to: DDD.Dialect.Postgres
        defdelegate retryable?(error), to: DDD.Dialect.Postgres

        # The first update of each test is aborted, the next ones are fine.
        def update_versioned(repo, schema, pk, fields, rows) do
          if Process.get(:aborted) do
            DDD.Dialect.Postgres.update_versioned(repo, schema, pk, fields, rows)
          else
            Process.put(:aborted, true)

            raise %Postgrex.Error{
              postgres: %{code: :deadlock_detected, message: "deadlock detected"}
            }
          end
        end
      end

      Application.put_env(:vicander, :dialect, DeadlockingDialect)
      on_exit(fn -> Application.delete_env(:vicander, :dialect) end)

      change = fn ->
        {:ok, note} = PgNotes.find_by_id(saved.id)
        {:ok, note} = Note.retitle(note, "written")
        PgNotes.save(note)
      end

      # As a unit of work: an error to the caller, nothing written.
      assert {:error, %DDD.Error{code: :deadlock_detected}} = UnitOfWork.run(change)
      assert row(saved.id) == [["first", 1]]

      # As a command that retries: the second attempt writes.
      Process.delete(:aborted)

      defmodule RetriedWrite do
        @moduledoc false
        use DDD.Command, retry_on_conflict: 2

        command do
          field :id, :string, required: true
        end

        @impl DDD.Command
        def execute(%{id: id}) do
          with {:ok, note} <- DDD.UnitOfWorkTest.PgNotes.find_by_id(id),
               {:ok, note} <- DDD.UnitOfWorkTest.Note.retitle(note, "retried"),
               do: DDD.UnitOfWorkTest.PgNotes.save(note)
        end
      end

      assert {:ok, %{text: "retried"}} = RetriedWrite.call(%{id: saved.id})
      assert row(saved.id) == [["retried", 2]]
    end
  end

  describe "loads:" do
    test "reads the declared aggregates with one query, and find_by_id then costs none" do
      notes = saved_notes(10)
      Process.put(:probe, self())

      {{:ok, renamed}, queries} =
        all_queries(fn -> RenameMany.call(%{ids: Enum.map(notes, & &1.id), text: "x"}) end)

      assert length(renamed) == 10
      assert count_of(queries, ~s(FROM "uow_notes")) == 1
      assert count_of(queries, ~s(UPDATE "uow_notes")) == 1

      # Ten loaded, and ten `find_by_id` answered from memory.
      assert_received {:executed, %{loaded: 10, hits: 0}}
      for note <- notes, do: assert(row(note.id) == [["x", 2]])
    end

    test "a declared id that does not exist fails the command before it does anything" do
      [a, b] = saved_notes(2)
      missing_one = Ecto.UUID.generate()
      missing_two = Ecto.UUID.generate()
      Process.put(:probe, self())

      assert {:error, %DDD.Error{} = error} =
               RenameMany.call(%{ids: [a.id, missing_one, b.id, missing_two], text: "x"})

      assert error.kind == :business
      assert error.code == :not_found
      assert error.entity == Note
      assert error.entity_id == missing_one
      assert error.details == %{field: :ids, missing_ids: [missing_one, missing_two]}
      assert error.context == %{command: RenameMany}
      assert error.message =~ missing_two

      refute_received {:executed, _}
      assert row(a.id) == [[a.text, 1]]
      assert events() == 0
    end

    test "an id that is not even the right type is one that does not exist" do
      assert {:error, %DDD.Error{code: :not_found, details: %{missing_ids: ["not-a-uuid"]}}} =
               RenameMany.call(%{ids: ["not-a-uuid"], text: "x"})
    end

    test "an empty or missing declaration loads nothing" do
      {result, queries} = all_queries(fn -> RenameTwo.call(%{}) end)

      assert result == {:ok, []}
      assert count_of(queries, ~s(FROM "uow_notes")) == 0

      assert {:ok, []} = RenameMany.call(%{ids: [], text: "x"})
    end

    test "fields that name the same repository are read together" do
      [a, b] = saved_notes(2)

      {{:ok, [first, second]}, queries} =
        all_queries(fn -> RenameTwo.call(%{first_id: a.id, second_id: b.id}) end)

      assert {:ok, %{id: id_a}} = first
      assert {:ok, %{id: id_b}} = second
      assert {id_a, id_b} == {a.id, b.id}
      assert count_of(queries, ~s(FROM "uow_notes")) == 1
    end

    test "the first field with a missing id is the one reported" do
      [a] = saved_notes(1)
      missing = Ecto.UUID.generate()

      assert {:error, %DDD.Error{details: %{field: :second_id, missing_ids: [^missing]}}} =
               RenameTwo.call(%{first_id: a.id, second_id: missing})
    end

    test "an aggregate that is not declared still loads when it is asked for", %{saved: saved} do
      defmodule Undeclared do
        @moduledoc false
        use DDD.Command

        command do
          field :id, :string, required: true
        end

        @impl DDD.Command
        def execute(%{id: id}), do: DDD.UnitOfWorkTest.PgNotes.find_by_id(id)
      end

      assert {:ok, %{id: id}} = Undeclared.call(%{id: saved.id})
      assert id == saved.id
    end

    test "can name a port, which gives the adapter through impl/0" do
      defmodule ViaPort do
        @moduledoc false
        use DDD.Command

        command do
          field :ids, {:array, :string}, required: true, loads: NotePortWithImpl
        end

        @impl DDD.Command
        def execute(%{ids: ids}),
          do: {:ok, Enum.map(ids, &elem(DDD.UnitOfWorkTest.PgNotes.find_by_id(&1), 1))}
      end

      notes = saved_notes(3)
      ids = Enum.map(notes, & &1.id)

      {{:ok, found}, queries} = all_queries(fn -> ViaPort.call(%{ids: ids}) end)
      assert Enum.map(found, & &1.id) == ids
      assert count_of(queries, ~s(FROM "uow_notes")) == 1

      assert {:error, %DDD.Error{code: :not_found, entity: Note}} =
               ViaPort.call(%{ids: [Ecto.UUID.generate()]})
    end

    test "can name the aggregate, whose repository is configured once" do
      defmodule ByAggregate do
        @moduledoc false
        use DDD.Command

        command do
          field :ids, {:array, :string}, required: true, loads: DDD.UnitOfWorkTest.Note
          field :other_id, {:ref, DDD.UnitOfWorkTest.Note}, loads: true
        end

        @impl DDD.Command
        def execute(%{ids: ids, other_id: other}) do
          found = for id <- ids ++ List.wrap(other), do: DDD.UnitOfWorkTest.PgNotes.find_by_id(id)
          {:ok, Enum.map(found, &elem(&1, 1))}
        end
      end

      notes = saved_notes(4)
      [a, b, c, d] = Enum.map(notes, & &1.id)

      # An adapter, or a port with impl/0, for the aggregate.
      for repository <- [DDD.UnitOfWorkTest.PgNotes, DDD.UnitOfWorkTest.NotePortWithImpl] do
        Application.put_env(:vicander, :repositories, [{Note, repository}])

        {{:ok, found}, queries} =
          all_queries(fn -> ByAggregate.call(%{ids: [a, b, c], other_id: d}) end)

        assert Enum.map(found, & &1.id) == [a, b, c, d]
        # The `ids` field and the `{:ref, ...}` field are the same aggregate: one query.
        assert count_of(queries, ~s(FROM "uow_notes")) == 1
      end

      assert {:error, %DDD.Error{code: :not_found, entity: Note, details: details}} =
               ByAggregate.call(%{ids: [a], other_id: missing = Ecto.UUID.generate()})

      assert details == %{field: :other_id, missing_ids: [missing]}
    end

    test "an aggregate with no repository configured says how to configure one" do
      Application.put_env(:vicander, :repositories, [])

      defmodule Unconfigured do
        @moduledoc false
        use DDD.Command

        command do
          field :id, :string, loads: DDD.UnitOfWorkTest.Note
        end

        @impl DDD.Command
        def execute(_), do: {:ok, :never}
      end

      assert_raise ArgumentError, ~r/config :vicander, :repositories/, fn ->
        Unconfigured.call(%{id: Ecto.UUID.generate()})
      end

      Application.put_env(:vicander, :repositories, [{Note, Enum}])

      assert_raise ArgumentError, ~r/the repository configured for .*Note.*Enum.*is not/, fn ->
        Unconfigured.call(%{id: Ecto.UUID.generate()})
      end
    end

    test "loads: true needs a {:ref, Aggregate} field" do
      assert_raise ArgumentError,
                   ~r/`loads: true` on :id needs a `\{:ref, Aggregate\}` field/,
                   fn ->
                     Code.eval_string("""
                     defmodule DDD.UnitOfWorkTest.NoRef do
                       use DDD.Command

                       command do
                         field :id, :string, loads: true
                       end

                       def execute(_), do: {:ok, :never}
                     end
                     """)
                   end
    end

    test "works with an in-memory repository" do
      start_supervised!(MemNotes)
      {:ok, note} = Note.new(text: "mem")
      {:ok, saved} = MemNotes.save(note)

      assert {:ok, {found, %{loaded: 1, hits: 1}}} = MemRename.call(%{id: saved.id})
      assert found.id == saved.id

      assert {:error, %DDD.Error{code: :not_found, entity: Note}} =
               MemRename.call(%{id: Ecto.UUID.generate()})
    end

    test "cannot be combined with unit_of_work: false" do
      assert_raise ArgumentError, ~r/`loads:` puts the aggregates in the unit of work/, fn ->
        Code.eval_string("""
        defmodule DDD.UnitOfWorkTest.Impossible do
          use DDD.Command, unit_of_work: false

          command do
            field :id, :string, loads: DDD.UnitOfWorkTest.PgNotes
          end

          def execute(_), do: {:ok, :never}
        end
        """)
      end
    end

    test "a repository that cannot load many is refused with a clear message" do
      defmodule NotARepository do
        @moduledoc false
        use DDD.Command

        command do
          field :id, :string, loads: Enum
        end

        @impl DDD.Command
        def execute(_), do: {:ok, :never}
      end

      assert_raise ArgumentError,
                   ~r/`loads: Enum` is not an aggregate, a repository adapter, nor a port/,
                   fn ->
                     NotARepository.call(%{id: "x"})
                   end
    end
  end

  describe "updated_at" do
    defp stored_updated_at(id) do
      Repo.query!("SELECT updated_at FROM uow_notes WHERE id = $1", [Ecto.UUID.dump!(id)]).rows
      |> hd()
      |> hd()
    end

    test "an operation leaves it alone; the write sets it", %{saved: saved} do
      Process.sleep(5)
      {:ok, renamed} = Note.rename(saved, "renamed")
      assert renamed.updated_at == saved.updated_at

      assert {:ok, written} = UnitOfWork.run(fn -> PgNotes.save(renamed) end)
      assert DateTime.compare(written.updated_at, saved.updated_at) == :gt
      assert written.created_at == saved.created_at

      # What the caller got back is what was stored.
      assert stored_updated_at(saved.id) == DateTime.to_naive(written.updated_at)
    end

    test "is set at once, outside a unit of work", %{saved: saved} do
      Process.sleep(5)
      {:ok, renamed} = Note.rename(saved, "renamed")

      assert {:ok, written} = PgNotes.save(renamed)
      assert DateTime.compare(written.updated_at, saved.updated_at) == :gt
      assert stored_updated_at(saved.id) == DateTime.to_naive(written.updated_at)
    end

    test "does not change when nothing that is stored changed", %{saved: saved} do
      Process.sleep(5)

      {{:ok, again}, queries} =
        all_queries(fn ->
          UnitOfWork.run(fn ->
            {:ok, note} = PgNotes.find_by_id(saved.id)
            {:ok, note} = Note.rename(note, note.text)
            PgNotes.save(note)
          end)
        end)

      # Its event is written; the row is not rewritten, so neither version nor time moved.
      assert again.updated_at == saved.updated_at
      assert count_of(queries, ~s(UPDATE "uow_notes")) == 0
      assert row(saved.id) == [["first", 1]]
      assert stored_updated_at(saved.id) == DateTime.to_naive(saved.updated_at)
      assert events() == 1
    end

    test "is set when the write changes something, and only once per unit of work", %{
      saved: saved
    } do
      Process.sleep(5)

      assert {:ok, final} =
               UnitOfWork.run(fn ->
                 {:ok, note} = PgNotes.find_by_id(saved.id)
                 {:ok, note} = Note.rename(note, "one")
                 {:ok, note} = PgNotes.save(note)
                 {:ok, note} = Note.rename(note, "two")
                 PgNotes.save(note)
               end)

      assert final.text == "two"
      assert DateTime.compare(final.updated_at, saved.updated_at) == :gt
      assert stored_updated_at(saved.id) == DateTime.to_naive(final.updated_at)
    end

    test "a new aggregate keeps the time `new` gave it" do
      {:ok, note} = Note.new(text: "new")
      assert note.created_at == note.updated_at

      assert {:ok, written} = UnitOfWork.run(fn -> PgNotes.save(note) end)
      assert written.updated_at == note.updated_at
    end
  end

  describe "in memory" do
    setup do
      start_supervised!(MemNotes)
      {:ok, note} = Note.new(text: "mem")
      {:ok, saved} = MemNotes.save(note)
      %{mem: saved}
    end

    test "a repository without a database takes part too", %{mem: mem} do
      UnitOfWork.run(fn ->
        {:ok, note} = MemNotes.find_by_id(mem.id)
        {:ok, note} = Note.rename(note, "renamed")
        assert {:ok, %{version: 2}} = MemNotes.save(note)

        # Still the stored one until the unit ends.
        assert {:ok, %{text: "mem", version: 1}} = MemNotes.__load__(mem.id)
        assert {:ok, %{text: "renamed"}} = MemNotes.find_by_id(mem.id)
        {:ok, :done}
      end)

      assert {:ok, %{text: "renamed", version: 2}} = MemNotes.find_by_id(mem.id)
    end

    test "all and count raise once something is saved, as the Ecto adapter's queries do", %{
      mem: mem
    } do
      for {name, query} <- [all: &MemNotes.all/0, count: &MemNotes.count/0] do
        assert_raise PendingChangesError, ~r/MemNotes\.#{name} reads the database/, fn ->
          UnitOfWork.run(fn ->
            {:ok, note} = MemNotes.find_by_id(mem.id)
            {:ok, note} = Note.rename(note, "pending")
            {:ok, _} = MemNotes.save(note)
            query.()
          end)
        end
      end

      # Nothing was written by the failed units.
      assert {:ok, %{text: "mem", version: 1}} = MemNotes.find_by_id(mem.id)
    end

    test "all and count are fine before the first save, and outside a unit of work", %{mem: mem} do
      assert MemNotes.count() == 1
      assert [%{id: id}] = MemNotes.all()
      assert id == mem.id

      assert {:ok, :done} =
               UnitOfWork.run(fn ->
                 assert MemNotes.count() == 1
                 {:ok, note} = MemNotes.find_by_id(mem.id)
                 {:ok, note} = Note.rename(note, "later")
                 {:ok, _} = MemNotes.save(note)
                 # A by-id read is always fine.
                 assert {:ok, _} = MemNotes.find_by_id(mem.id)
                 {:ok, :done}
               end)

      assert MemNotes.count() == 1
    end

    test "an update sets updated_at and keeps created_at", %{mem: mem} do
      Process.sleep(5)
      {:ok, renamed} = Note.rename(mem, "renamed")
      assert renamed.updated_at == mem.updated_at

      assert {:ok, written} = MemNotes.save(renamed)
      assert DateTime.compare(written.updated_at, mem.updated_at) == :gt
      assert written.created_at == mem.created_at
    end

    test "what save returned is what is stored", %{mem: mem} do
      Process.sleep(5)
      {:ok, renamed} = Note.rename(mem, "renamed")

      assert {:ok, returned} = UnitOfWork.run(fn -> MemNotes.save(renamed) end)
      assert {:ok, ^returned} = MemNotes.find_by_id(mem.id)
    end

    test "delete is deferred and then applied", %{mem: mem} do
      UnitOfWork.run(fn ->
        {:ok, note} = MemNotes.find_by_id(mem.id)
        :ok = MemNotes.delete(note)
        assert {:ok, _} = MemNotes.__load__(mem.id)
        {:ok, :done}
      end)

      assert {:error, :not_found} = MemNotes.find_by_id(mem.id)
    end
  end

  describe "commands" do
    test "run in a unit of work unless they opt out" do
      assert Rename.__cmd_uow__() == true

      defmodule OptOut do
        @moduledoc false
        use DDD.Command, unit_of_work: false

        command do
          field :id, :string, required: true
        end

        @impl DDD.Command
        def execute(_), do: {:ok, DDD.UnitOfWork.open?()}
      end

      assert OptOut.__cmd_uow__() == false
      assert {:ok, false} = OptOut.call(%{id: "x"})
    end

    test "a command called inside another command joins its unit of work", %{saved: saved} do
      defmodule Outer do
        @moduledoc false
        use DDD.Command

        command do
          field :id, :string, required: true
        end

        @impl DDD.Command
        def execute(%{id: id}) do
          {:ok, _} = DDD.UnitOfWorkTest.Rename.call(%{id: id, text: "inner"})
          {:ok, DDD.TestRepo.query!("SELECT text FROM uow_notes").rows}
        end
      end

      # The inner command saved, but nothing is written until the outer one ends.
      assert {:ok, [["first"]]} = Outer.call(%{id: saved.id})
      assert row(saved.id) == [["inner", 2]]
    end
  end
end
