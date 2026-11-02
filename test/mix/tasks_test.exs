defmodule Mix.Tasks.VicTasksTest do
  # Not async: Mix.shell and the working directory are global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Vic.Gen

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp args(dir, extra) do
    extra ++
      ["--snapshot-dir", Path.join(dir, "snap"), "--migrations-path", Path.join(dir, "mig")]
  end

  describe "vic.gen.migration" do
    test "creates a migration, then reports no changes", %{tmp_dir: dir} do
      Gen.Migration.run(args(dir, ["DDD.Test.Account", "DDD.Test.Ledger"]))

      assert_received {:mix_shell, :info, [created1]}
      assert_received {:mix_shell, :info, [created2]}
      assert IO.iodata_to_binary(created1) =~ "create_accounts"
      assert IO.iodata_to_binary(created2) =~ "create_ledgers"

      versions =
        dir |> Path.join("mig") |> File.ls!() |> Enum.map(&(&1 |> String.split("_") |> hd()))

      assert length(Enum.uniq(versions)) == 2

      Gen.Migration.run(args(dir, ["DDD.Test.Account"]))
      assert_received {:mix_shell, :info, ["DDD.Test.Account: no changes"]}
    end

    test "fails on destructive changes with a hint", %{tmp_dir: dir} do
      Gen.Migration.run(args(dir, ["DDD.Test.Account"]))
      snapshot = Path.join([dir, "snap", "ddd.test.account.json"])
      data = snapshot |> File.read!() |> Jason.decode!()
      extra = %{"name" => "legacy", "type" => ":string", "primary_key" => false}
      File.write!(snapshot, Jason.encode!(%{data | "columns" => data["columns"] ++ [extra]}))

      assert_raise Mix.Error,
                   ~r/destructive changes \(remove column legacy\).*--allow-destructive/,
                   fn ->
                     Gen.Migration.run(args(dir, ["DDD.Test.Account"]))
                   end

      Gen.Migration.run(args(dir, ["DDD.Test.Account", "--allow-destructive"]))
      assert [_, _] = dir |> Path.join("mig") |> File.ls!()
    end

    test "honours --rename and --table", %{tmp_dir: dir} do
      Gen.Migration.run(args(dir, ["DDD.Test.Account", "--table", "people", "--repo", "My.Repo"]))

      [file] = File.ls!(Path.join(dir, "mig"))
      assert file =~ "create_people"
      assert File.read!(Path.join([dir, "mig", file])) =~ "My.Repo.Migrations.CreatePeople"

      snapshot = Path.join([dir, "snap", "ddd.test.account.json"])
      data = snapshot |> File.read!() |> Jason.decode!()

      renamed =
        Enum.map(
          data["columns"],
          &if(&1["name"] == "name", do: %{&1 | "name" => "full_name"}, else: &1)
        )

      File.write!(snapshot, Jason.encode!(%{data | "columns" => renamed}))

      Gen.Migration.run(args(dir, ["DDD.Test.Account", "--rename", "full_name:name"]))
      alter = dir |> Path.join("mig") |> File.ls!() |> Enum.find(&(&1 =~ "alter_people"))

      assert File.read!(Path.join([dir, "mig", alter])) =~
               "rename table(:people), :full_name, to: :name"
    end

    test "validates its input", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/usage/, fn -> Gen.Migration.run([]) end

      assert_raise Mix.Error, ~r/not a DDD aggregate/, fn ->
        Gen.Migration.run(args(dir, ["String"]))
      end

      assert_raise Mix.Error, ~r/--rename expects old:new/, fn ->
        Gen.Migration.run(args(dir, ["DDD.Test.Account", "--rename", "nocolon"]))
      end
    end
  end

  describe "vic.gen.outbox_migration" do
    test "writes the outbox migration into priv/repo/migrations", %{tmp_dir: dir} do
      File.cd!(dir, fn -> Gen.OutboxMigration.run([]) end)

      assert_received {:mix_shell, :info, [_]}
      [file] = File.ls!(Path.join(dir, "priv/repo/migrations"))
      assert file =~ "_create_domain_events.exs"

      source = File.read!(Path.join([dir, "priv/repo/migrations", file]))
      assert source =~ "create table(:domain_events"
      # Named after the application's configured repo.
      assert source =~ "defmodule DDD.TestRepo.Migrations.CreateDomainEvents"
    end
  end
end
