defmodule DDD.QueryTest do
  use DDD.DataCase

  import ExUnit.CaptureLog

  alias DDD.Error

  defmodule Count do
    @moduledoc false
    use DDD.Query

    query do
      description "How many rows a table has"
      field :min, :integer, default: 0, description: "Ignore rows below this"
      field :label, :string, required: true
    end

    @impl DDD.Query
    def execute(%__MODULE__{min: min, label: label}) do
      %{rows: [[n]]} = DDD.TestRepo.query!("SELECT count(*) FROM notes WHERE n >= $1", [min])
      {:ok, %{label: label, count: n}}
    end
  end

  # The SQL sandbox keeps one transaction open around every test, so the read-only mode is
  # exercised on a repo of its own with a real connection (one connection: temp tables stay).
  defmodule RawRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :vicander, adapter: Ecto.Adapters.Postgres
  end

  defmodule Sneaky do
    @moduledoc false
    use DDD.Query, repo: DDD.QueryTest.RawRepo

    query do
      field :n, :integer, required: true
    end

    @impl DDD.Query
    def execute(%__MODULE__{n: n}) do
      DDD.QueryTest.RawRepo.query!("INSERT INTO raw_notes (n) VALUES ($1)", [n])
      {:ok, :written}
    end
  end

  defmodule RawCount do
    @moduledoc false
    use DDD.Query, repo: DDD.QueryTest.RawRepo

    query do
    end

    @impl DDD.Query
    def execute(_) do
      %{rows: [[n]]} = DDD.QueryTest.RawRepo.query!("SELECT count(*) FROM raw_notes")
      {:ok, n}
    end
  end

  defmodule Failing do
    @moduledoc false
    use DDD.Query

    query do
    end

    @impl DDD.Query
    def execute(_), do: {:error, :nothing_here}
  end

  defmodule Broken do
    @moduledoc false
    use DDD.Query

    query do
    end

    @impl DDD.Query
    def execute(_), do: :oops
  end

  defmodule Crashing do
    @moduledoc false
    use DDD.Query

    query do
    end

    @impl DDD.Query
    def execute(_), do: raise("boom")
  end

  defmodule Plain do
    @moduledoc false
    use DDD.Query, transaction: false

    query do
      field :x, :string
    end

    @impl DDD.Query
    def execute(%__MODULE__{x: x}), do: {:ok, x}

    def repo, do: __query_repo__()
  end

  setup do
    Repo.query!("CREATE TEMP TABLE notes (n integer)")
    Repo.query!("INSERT INTO notes VALUES (1), (5), (9)")
    :ok
  end

  test "a query declares its parameters and description" do
    assert Count.__description__() == "How many rows a table has"
    assert [{:min, :integer, min_opts}, {:label, :string, _}] = Count.__params__()
    assert min_opts[:description] == "Ignore rows below this"
    assert Plain.__description__() == nil
  end

  test "call/1 validates, runs and returns the result" do
    assert {:ok, %{label: "all", count: 3}} = Count.call(label: "all")
    assert {:ok, %{count: 2}} = Count.call(%{label: "big", min: 5})
    {:ok, query} = Count.new(label: "x")
    assert {:ok, %{count: 3}} = Count.call(query)
    assert %{count: 3} = Count.call!(label: "x")
  end

  test "bad input comes back as a validation error with the query as context" do
    assert {:error, %Error{kind: :business} = error} = Count.call(%{})
    assert [%{field: :label, code: :required}] = error.violations
    assert error.context == %{query: Count}

    assert {:error, error} = Count.call(label: 5)
    assert Error.codes(error) == [:invalid_type]
  end

  describe "on a real connection" do
    setup do
      config =
        :vicander
        |> Application.fetch_env!(DDD.TestRepo)
        |> Keyword.drop([:pool])
        |> Keyword.put(:pool_size, 1)

      # Postgres lets a read-only transaction write to a TEMP table, so this one is real.
      start_supervised!({RawRepo, config})
      RawRepo.query!("DROP TABLE IF EXISTS raw_notes")
      RawRepo.query!("CREATE TABLE raw_notes (n integer)")
      RawRepo.query!("INSERT INTO raw_notes VALUES (1)")

      on_exit(fn ->
        {:ok, conn} = Postgrex.start_link(Keyword.drop(config, [:pool_size, :log, :stacktrace]))
        Postgrex.query!(conn, "DROP TABLE IF EXISTS raw_notes", [])
      end)

      :ok
    end

    test "a query cannot write: the database refuses, and nothing is left behind" do
      capture_log(fn ->
        assert_raise Postgrex.Error, ~r/read-only transaction/, fn -> Sneaky.call(n: 99) end
      end)

      assert {:ok, 1} = RawCount.call(%{})
    end

    test "the read-only mode does not leak: writes work again afterwards" do
      assert {:ok, 1} = RawCount.call(%{})
      assert %{num_rows: 1} = RawRepo.query!("INSERT INTO raw_notes VALUES (2)")
      assert {:ok, 2} = RawCount.call(%{})
    end
  end

  test "an error result is wrapped, a wrong return value is a programming error" do
    assert {:error, %Error{} = error} = Failing.call(%{})
    assert error.code == :nothing_here
    assert error.context == %{query: Failing}

    capture_log(fn ->
      assert_raise ArgumentError, ~r/must return \{:ok, _\} or \{:error, _\}/, fn ->
        Broken.call(%{})
      end

      assert_raise RuntimeError, "boom", fn -> Crashing.call(%{}) end
    end)

    assert_raise RuntimeError, ~r/Query .*Failing failed/, fn -> Failing.call!(%{}) end
  end

  test "transaction: false runs without one" do
    assert Plain.repo() == nil
    assert {:ok, "a"} = Plain.call(x: "a")
  end

  test "a query called inside an open transaction joins it" do
    assert {:ok, {:ok, %{count: 3}}} =
             Repo.transaction(fn -> Count.call(label: "inside") end)
  end

  test "it is logged as a read" do
    log = capture_log(fn -> Count.call(label: "x") end)
    assert log =~ "[query]" and log =~ "Count"
  end
end
