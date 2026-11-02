defmodule DDD.ReviewFixesTest do
  # Regressions for the problems found in the code review of lib/ddd.
  use DDD.DataCase

  alias DDD.{Error, Type}

  defmodule Memo do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :owner_id, :uuid
      field :notes, :string
      field :mood, :atom
    end
  end

  defmodule MemoRepository do
    @moduledoc false
    use DDD.Repository

    repo Memo do
      find_by :owner_id
    end
  end

  defmodule PgMemoRepository do
    @moduledoc false
    use DDD.Repository.Ecto, port: DDD.ReviewFixesTest.MemoRepository, repo: DDD.TestRepo
  end

  defmodule Flag do
    @moduledoc false
    use DDD.ValueObject

    value_object do
      field :on, :boolean, default: true
      field :label, :string
    end
  end

  defmodule Flagged do
    @moduledoc false
    use DDD.Command, transaction: false

    command do
      description "Takes a nested value object"
      field :flag, {:one, DDD.ReviewFixesTest.Flag}
      field :flags, {:list, DDD.ReviewFixesTest.Flag}
    end

    def execute(_), do: {:ok, 1}
  end

  setup do
    Repo.query!("""
    CREATE TEMP TABLE memos (
      id uuid PRIMARY KEY, owner_id uuid, notes text, mood varchar,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
        version bigint NOT NULL DEFAULT 0
    )
    """)

    :ok
  end

  describe "blank strings are stored as they are" do
    test "an empty string and a whitespace-only string are not turned into NULL" do
      for notes <- ["", "   ", "\n"] do
        {:ok, memo} = Memo.new(notes: notes)
        assert {:ok, _} = PgMemoRepository.save(memo)
        assert {:ok, found} = PgMemoRepository.find_by_id(memo.id)
        assert found.notes == notes
      end
    end

    test "nil still means nothing" do
      {:ok, memo} = Memo.new([])
      assert {:ok, _} = PgMemoRepository.save(memo)
      assert {:ok, %{notes: nil}} = PgMemoRepository.find_by_id(memo.id)
    end
  end

  describe "an id of the wrong type names nothing" do
    test "find_by_id returns :not_found instead of raising" do
      assert {:error, :not_found} = PgMemoRepository.find_by_id("not-a-uuid")
      assert {:error, :not_found} = PgMemoRepository.find_by_id(12)
    end

    test "a finder with a value of the wrong type finds nothing" do
      assert PgMemoRepository.find_by_owner_id("not-a-uuid") == []
    end

    test "a real one still works" do
      owner = UUID.uuid4()
      {:ok, memo} = Memo.new(owner_id: owner)
      {:ok, _} = PgMemoRepository.save(memo)
      assert [%{id: id}] = PgMemoRepository.find_by_owner_id(owner)
      assert id == memo.id
    end
  end

  describe ":atom fields" do
    test "a stored atom is readable even if nothing has defined it yet" do
      name = "never_defined_#{System.unique_integer([:positive])}"
      {:ok, memo} = Memo.new(mood: :calm)
      {:ok, _} = PgMemoRepository.save(memo)
      Repo.query!("UPDATE memos SET mood = $1", [name])

      assert {:ok, %{mood: mood}} = PgMemoRepository.find_by_id(memo.id)
      assert Atom.to_string(mood) == name

      assert Type.json_load(:atom, "another_#{System.unique_integer([:positive])}") |> is_atom()
    end
  end

  describe "the seal" do
    test "update/2 refuses a struct the framework did not produce" do
      {:ok, memo} = Memo.new(notes: "a")
      tampered = %{memo | notes: "b"}

      assert {:error, %Error{code: :unsealed, operation: :update}} =
               Memo.update(tampered, notes: "c")

      assert {:error, %Error{code: :unsealed}} = Memo.update(tampered, &%{&1 | notes: "c"})
      assert {:ok, %{notes: "c"}} = Memo.update(memo, notes: "c")
    end

    test "new/1 ignores a seal or pending events smuggled in the attributes" do
      {:ok, memo} = Memo.new(notes: "a", __sealed__: 1, __pending_events__: [:forged])
      assert Memo.pop_events(memo) == {[], memo}
      assert DDD.Schema.sealed?(memo)
    end

    test "validate/1 still validates a modified struct (and seals it when it is valid)" do
      {:ok, memo} = Memo.new(owner_id: UUID.uuid4())
      assert {:ok, _} = Memo.validate(%{memo | notes: "fine"})
      assert {:error, _} = Memo.validate(%{memo | owner_id: "nope"})
    end
  end

  describe "false is a value" do
    test "a nested value object keeps a false that the client sent" do
      assert {:ok, %{flag: %Flag{on: false, label: "x"}}} =
               DDD.MCP.Args.cast(Flagged, %{"flag" => %{"on" => false, "label" => "x"}})

      assert {:ok, %{flags: [%Flag{on: false}, %Flag{on: true}]}} =
               DDD.MCP.Args.cast(Flagged, %{
                 "flags" => [%{"on" => false}, %{"label" => "default is true"}]
               })
    end
  end
end
