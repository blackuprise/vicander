defmodule DDD.MigrationTest do
  use ExUnit.Case, async: true

  alias DDD.Migration

  defmodule Doc do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :title, :string
      field :body, :string, renamed_from: :text
      field :tags, {:list, DDD.MigrationTest.Doc}, default: []
      field :inserted_at, :datetime
    end
  end

  defmodule Note do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :headline, :string, required: true
      field :summary, :string
    end
  end

  @col_id %{"name" => "id", "type" => ":binary_id", "primary_key" => true}
  @col_text %{"name" => "text", "type" => ":string", "primary_key" => false}
  @col_body %{"name" => "body", "type" => ":string", "primary_key" => false}
  @col_old %{"name" => "old", "type" => ":string", "primary_key" => false}

  @moduletag :tmp_dir

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

  test "default_table/1 pluralises the last module segment" do
    assert Migration.default_table(Doc) == "docs"
  end

  describe "columns/1" do
    test "maps fields to Ecto types and adds missing timestamps" do
      columns = Migration.columns(Doc)

      assert Enum.map(columns, & &1["name"]) == [
               "id",
               "title",
               "body",
               "tags",
               "inserted_at",
               "created_at",
               "updated_at",
               "version"
             ]

      assert %{"type" => ":binary_id", "primary_key" => true} = hd(columns)
      assert Enum.find(columns, &(&1["name"] == "tags"))["type"] == ":map"
      assert Enum.find(columns, &(&1["name"] == "created_at"))["type"] == ":utc_datetime_usec"
      assert Enum.find(columns, &(&1["name"] == "updated_at"))["type"] == ":utc_datetime_usec"
    end

    test "declared_renames/1 reads renamed_from" do
      assert Migration.declared_renames(Doc) == %{"text" => "body"}
    end
  end

  describe "diff/3" do
    test "added, removed and changed columns" do
      old = [@col_id, @col_old, %{@col_body | "type" => ":text"}]

      new = [
        @col_id,
        @col_body,
        %{"name" => "extra", "type" => ":integer", "primary_key" => false}
      ]

      diff = Migration.diff(old, new)

      assert [%{"name" => "extra"}] = diff.added
      assert [%{"name" => "old"}] = diff.removed
      assert [{"body", ":text", ":string"}] = diff.changed
      assert diff.renamed == []
      assert Migration.destructive?(diff)
      refute Migration.empty?(diff)
    end

    test "a declared rename keeps the data (no add/remove)" do
      diff = Migration.diff([@col_id, @col_text], [@col_id, @col_body], %{"text" => "body"})
      assert diff.renamed == [{"text", "body"}]
      assert diff.added == [] and diff.removed == [] and diff.changed == []
      refute Migration.destructive?(diff)
    end

    test "a rename with a type change is also a type change" do
      diff =
        Migration.diff([@col_id, @col_text], [@col_id, %{@col_body | "type" => ":text"}], %{
          "text" => "body"
        })

      assert [{"body", ":string", ":text"}] = diff.changed
    end

    test "without a declared rename it is a remove plus an add" do
      diff = Migration.diff([@col_id, @col_text], [@col_id, @col_body])
      assert [%{"name" => "body"}] = diff.added
      assert [%{"name" => "text"}] = diff.removed
    end

    test "identical columns are empty" do
      assert Migration.empty?(Migration.diff([@col_id], [@col_id]))
    end
  end

  describe "generate/2" do
    test "first run writes a create migration and a snapshot", %{tmp_dir: dir} do
      assert {:ok, path} = Migration.generate(Doc, opts(dir))
      assert Path.basename(path) == "20300101000000_create_docs.exs"

      content = File.read!(path)
      assert content =~ "defmodule MyApp.Repo.Migrations.CreateDocs do"
      assert content =~ "create table(:docs, primary_key: false) do"
      assert content =~ "add :id, :binary_id, primary_key: true"
      assert content =~ "add :tags, :map"
      assert content =~ "add :updated_at, :utc_datetime_usec, null: false"
      assert Code.string_to_quoted!(content)

      snapshot = Path.join([dir, "snapshots", "ddd.migration_test.doc.json"])
      assert %{"table" => "docs", "columns" => [_ | _]} = Jason.decode!(File.read!(snapshot))
    end

    test "a second run without changes does nothing", %{tmp_dir: dir} do
      {:ok, _} = Migration.generate(Doc, opts(dir))
      assert {:ok, :unchanged} = Migration.generate(Doc, opts(dir, timestamp: "20300102000000"))
      assert length(File.ls!(Path.join(dir, "migrations"))) == 1
    end

    test "writes only the difference as an alter migration", %{tmp_dir: dir} do
      write_snapshot(dir, "docs", [
        @col_id,
        @col_text,
        %{"name" => "title", "type" => ":string", "primary_key" => false}
      ])

      assert {:ok, path} = Migration.generate(Doc, opts(dir, timestamp: "20300102000000"))
      assert Path.basename(path) == "20300102000000_alter_docs_20300102000000.exs"

      content = File.read!(path)
      assert content =~ "rename table(:docs), :text, to: :body"
      assert content =~ "alter table(:docs) do"
      assert content =~ "add :tags, :map"
      refute content =~ "DESTRUCTIVE"
      assert Code.string_to_quoted!(content)
    end

    test "refuses destructive changes unless allowed", %{tmp_dir: dir} do
      old = [@col_id, @col_old, %{"name" => "title", "type" => ":text", "primary_key" => false}]
      write_snapshot(dir, "docs", old)

      assert {:error, {:destructive, changes}} = Migration.generate(Doc, opts(dir))
      assert "remove column old" in changes
      assert "change title from :text to :string" in changes
      refute File.exists?(Path.join(dir, "migrations"))

      assert {:ok, path} = Migration.generate(Doc, opts(dir, allow_destructive: true))
      content = File.read!(path)
      assert content =~ "# DESTRUCTIVE: drops all data in old"
      assert content =~ "remove :old, :string"
      assert content =~ "modify :title, :string, from: :text"
      assert Code.string_to_quoted!(content)
    end

    test "explicit renames from options are honoured", %{tmp_dir: dir} do
      current = Enum.reject(Migration.columns(Doc), &(&1["name"] == "title"))
      write_snapshot(dir, "docs", current ++ [%{@col_old | "name" => "heading"}])

      assert {:ok, path} = Migration.generate(Doc, opts(dir, renames: %{"heading" => "title"}))

      assert File.read!(path) =~ "rename table(:docs), :heading, to: :title"
    end
  end

  describe "required: true" do
    test "is NOT NULL in a new table, and an optional field is not" do
      assert %{"null" => false} = Enum.find(Migration.columns(Note), &(&1["name"] == "headline"))
      refute Map.has_key?(Enum.find(Migration.columns(Note), &(&1["name"] == "summary")), "null")
    end

    test "a create migration says null: false for it", %{tmp_dir: dir} do
      assert {:ok, path} = Migration.generate(Note, opts(dir))

      content = File.read!(path)
      assert content =~ "add :headline, :string, null: false"
      assert content =~ ~r/add :summary, :string\n/
      assert Code.string_to_quoted!(content)
    end

    test "a column added to an existing table stays nullable", %{tmp_dir: dir} do
      # The table has rows: a NOT NULL column with no default would fail to be added.
      write_snapshot(dir, "notes", [@col_id], "ddd.migration_test.note.json")

      assert {:ok, path} = Migration.generate(Note, opts(dir))

      content = File.read!(path)
      assert content =~ "alter table(:notes) do"
      assert content =~ ~r/add :headline, :string\n/
      refute content =~ "add :headline, :string, null: false"
    end

    test "a table generated before this flag existed is not reported as changed", %{tmp_dir: dir} do
      old = [
        @col_id,
        %{"name" => "headline", "type" => ":string", "primary_key" => false},
        %{"name" => "summary", "type" => ":string", "primary_key" => false}
      ]

      current =
        Enum.filter(Migration.columns(Note), &(&1["name"] in ~w(created_at updated_at version)))

      write_snapshot(dir, "notes", old ++ current, "ddd.migration_test.note.json")

      assert {:ok, :unchanged} = Migration.generate(Note, opts(dir))
    end

    test "a diff does not treat the flag as a change" do
      assert Migration.diff(
               [%{"name" => "headline", "type" => ":string", "primary_key" => false}],
               [
                 %{
                   "name" => "headline",
                   "type" => ":string",
                   "primary_key" => false,
                   "null" => false
                 }
               ]
             )
             |> Migration.empty?()
    end
  end

  defp write_snapshot(dir, table, columns, name \\ "ddd.migration_test.doc.json") do
    path = Path.join([dir, "snapshots", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"table" => table, "columns" => columns}))
  end
end
