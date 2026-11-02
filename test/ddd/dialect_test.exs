defmodule DDD.DialectTest do
  use DDD.DataCase

  alias DDD.Dialect

  defmodule MysteryRepo do
    def __adapter__, do: Ecto.Adapters.Mystery
  end

  defmodule CustomDialect do
  end

  setup do
    on_exit(fn -> Application.delete_env(:vicander, :dialect) end)
  end

  describe "for_repo/1" do
    test "follows the adapter of the repo" do
      assert Dialect.for_repo(DDD.TestRepo) == DDD.Dialect.Postgres
    end

    test "an adapter without a dialect is refused, naming it" do
      error = assert_raise ArgumentError, fn -> Dialect.for_repo(MysteryRepo) end

      assert error.message =~ "Ecto.Adapters.Mystery"
      assert error.message =~ "DDD.DialectTest.MysteryRepo"
      assert error.message =~ "config :vicander, dialect:"
    end

    test "the configuration wins over the adapter" do
      Application.put_env(:vicander, :dialect, CustomDialect)

      assert Dialect.for_repo(DDD.TestRepo) == CustomDialect
      assert Dialect.for_repo(MysteryRepo) == CustomDialect
    end
  end

  describe "usec/1" do
    test "gives a datetime microsecond precision" do
      assert %{microsecond: {0, 6}} = Dialect.usec(~U[2026-01-01 00:00:00Z])
      assert %{microsecond: {123_000, 6}} = Dialect.usec(~U[2026-01-01 00:00:00.123Z])
    end
  end

  describe "Postgres" do
    test "now/1 is the database's UTC time" do
      now = DDD.Dialect.Postgres.now(DDD.TestRepo)

      assert now.time_zone == "Etc/UTC"
      assert abs(DateTime.diff(DateTime.utc_now(), now, :second)) < 3600
    end

    test "columns/2 lists the columns of a table, and none for a missing one" do
      columns = DDD.Dialect.Postgres.columns(DDD.TestRepo, "domain_events")

      assert "id" in columns and "locked_until" in columns
      assert DDD.Dialect.Postgres.columns(DDD.TestRepo, "no_such_table") == []
    end

    test "read_only/2 returns the result, and refuses a write" do
      assert {:ok, 1} = DDD.Dialect.Postgres.read_only(DDD.TestRepo, fn -> {:ok, 1} end)

      assert_raise Postgrex.Error, ~r/read-only transaction/, fn ->
        DDD.Dialect.Postgres.read_only(DDD.TestRepo, fn ->
          DDD.TestRepo.query!("DELETE FROM domain_events")
        end)
      end
    end
  end
end
