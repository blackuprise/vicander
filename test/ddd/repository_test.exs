defmodule DDD.RepositoryTest do
  use ExUnit.Case, async: true

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
      find_by :text
      find_by [:text, :id]
    end
  end

  defmodule PlainPort do
    use DDD.Repository

    repo Note do
    end
  end

  defmodule Store do
    use DDD.InMemoryRepository, port: PlainPort

    def find_by_id_or_nil(id), do: with({:ok, n} <- find_by_id(id), do: n)
  end

  setup do
    start_supervised!(Store)
    {:ok, note} = Note.new(text: "hello")
    %{note: note}
  end

  test "the port records its aggregate and finders" do
    assert NotePort.__repo_aggregate__() == Note
    assert NotePort.__repo_find_bys__() == [[:text], [:text, :id]]
  end

  describe "InMemoryRepository" do
    test "saves, finds, counts and deletes sealed aggregates", %{note: note} do
      assert {:ok, saved} = Store.save(note)
      assert saved.version == 1
      assert {:ok, ^saved} = Store.find_by_id(note.id)
      assert Store.find_by_id_or_nil(note.id) == saved
      assert Store.all() == [saved]
      assert Store.count() == 1

      assert :ok = Store.delete(saved)
      assert {:error, :not_found} = Store.find_by_id(note.id)

      Store.save(note)
      Store.clear()
      assert Store.count() == 0
    end

    test "refuses an aggregate that is not sealed", %{note: note} do
      tampered = %{note | text: "changed behind the framework's back"}

      assert {:error, %DDD.Error{code: :unsealed, entity: Note, operation: :save}} =
               Store.save(tampered)

      assert Store.count() == 0
    end
  end
end
