defmodule DDD.CommandTransactionTest do
  use DDD.DataCase

  import ExUnit.CaptureLog

  alias DDD.Error

  defmodule Stocked do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :name, :string
    end
  end

  defmodule Cart do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :owner_id, :uuid, required: true
      field :name, :string, required: true

      validate :name, &(String.trim(&1) != ""), message: "must not be blank"
    end

    defop stock(cart), do: emit_event(cart, Stocked.new(%{name: cart.name}))
  end

  defmodule CartRepository do
    @moduledoc false
    use DDD.Repository

    repo Cart do
    end
  end

  defmodule PgCartRepository do
    @moduledoc false
    use DDD.Repository.Ecto,
      port: DDD.CommandTransactionTest.CartRepository,
      repo: DDD.TestRepo,
      table: "test_carts"
  end

  defmodule Steps do
    @moduledoc false
    # Saves a first cart (with an event, so an outbox row is written), then a second one.
    # An invalid second name makes the command fail after the first save.
    def run(owner_id, second_name) do
      {:ok, first} = Cart.new(owner_id: owner_id, name: "First")
      {:ok, first} = Cart.stock(first)
      {:ok, _} = PgCartRepository.save(first)

      with {:ok, second} <- Cart.new(owner_id: owner_id, name: second_name) do
        PgCartRepository.save(second)
      end
    end
  end

  defmodule Atomic do
    @moduledoc false
    use DDD.Command

    command do
      field :owner_id, :string, required: true
      field :second_name, :string, required: true
    end

    @impl DDD.Command
    def execute(%__MODULE__{owner_id: owner_id, second_name: name}), do: Steps.run(owner_id, name)
  end

  # No transaction and no unit of work: every save is written at once and stays.
  defmodule NotAtomic do
    @moduledoc false
    use DDD.Command, transaction: false, unit_of_work: false

    command do
      field :owner_id, :string, required: true
      field :second_name, :string, required: true
    end

    @impl DDD.Command
    def execute(%__MODULE__{owner_id: owner_id, second_name: name}), do: Steps.run(owner_id, name)
  end

  # No transaction, but a unit of work: the saves are written only if the command succeeds.
  defmodule DeferredNoTransaction do
    @moduledoc false
    use DDD.Command, transaction: false

    command do
      field :owner_id, :string, required: true
      field :second_name, :string, required: true
    end

    @impl DDD.Command
    def execute(%__MODULE__{owner_id: owner_id, second_name: name}), do: Steps.run(owner_id, name)
  end

  defmodule Raises do
    @moduledoc false
    use DDD.Command, repo: DDD.TestRepo

    command do
      field :owner_id, :string, required: true
    end

    @impl DDD.Command
    def execute(%__MODULE__{owner_id: owner_id}) do
      Steps.run(owner_id, "Second")
      raise "boom after saving"
    end
  end

  defmodule SwallowsFailure do
    @moduledoc false
    use DDD.Command

    command do
      field :owner_id, :string, required: true
    end

    @impl DDD.Command
    def execute(%__MODULE__{owner_id: owner_id}) do
      Steps.run(owner_id, "Second")
      # A failed inner transaction poisons the outer one, even though we ignore the result.
      {:error, :oops} = Repo.transaction(fn -> Repo.rollback(:oops) end)
      {:ok, :looked_fine}
    end
  end

  defmodule BadReturn do
    @moduledoc false
    use DDD.Command

    command do
      field :owner_id, :string, required: true
    end

    @impl DDD.Command
    def execute(%__MODULE__{owner_id: owner_id}) do
      Steps.run(owner_id, "Second")
      :not_a_result_tuple
    end
  end

  defp count(table), do: Repo.query!("SELECT count(*) FROM #{table}").rows |> hd() |> hd()

  setup do
    %{owner_id: Ecto.UUID.generate()}
  end

  test "success commits everything the command did", %{owner_id: owner_id} do
    assert {:ok, %Cart{name: "Second"}} =
             Atomic.call(%{owner_id: owner_id, second_name: "Second"})

    assert count("test_carts") == 2
    assert count("domain_events") == 1
  end

  test "an error rolls back every aggregate and event saved before it", %{owner_id: owner_id} do
    assert {:error, %Error{} = error} = Atomic.call(%{owner_id: owner_id, second_name: " "})
    assert error.entity == Cart
    assert error.context == %{command: Atomic}

    assert count("test_carts") == 0
    assert count("domain_events") == 0
  end

  test "with transaction: false the earlier save stays committed", %{owner_id: owner_id} do
    assert {:error, %Error{}} = NotAtomic.call(%{owner_id: owner_id, second_name: " "})

    assert count("test_carts") == 1
    assert count("domain_events") == 1
  end

  test "with transaction: false but a unit of work, a failing command writes nothing",
       %{owner_id: owner_id} do
    assert {:error, %Error{}} =
             DeferredNoTransaction.call(%{owner_id: owner_id, second_name: " "})

    assert count("test_carts") == 0
    assert count("domain_events") == 0

    assert {:ok, _} = DeferredNoTransaction.call(%{owner_id: owner_id, second_name: "Second"})
    assert count("test_carts") == 2
    assert count("domain_events") == 1
  end

  test "an exception rolls back and propagates", %{owner_id: owner_id} do
    log =
      capture_log(fn ->
        assert_raise RuntimeError, "boom after saving", fn ->
          Raises.call(%{owner_id: owner_id})
        end
      end)

    assert log =~ "Raises crashed: boom after saving"
    assert count("test_carts") == 0
    assert count("domain_events") == 0
  end

  test "ignoring a failed inner transaction still rolls everything back", %{owner_id: owner_id} do
    assert {:error, %Error{code: :transaction_rolled_back, context: context}} =
             SwallowsFailure.call(%{owner_id: owner_id})

    assert context == %{command: SwallowsFailure}

    # A system failure, not the domain's decision: an event handler would retry it.
    assert {:error, %Error{kind: :infrastructure}} = SwallowsFailure.call(%{owner_id: owner_id})
    assert count("test_carts") == 0
  end

  test "a handler that returns something other than ok/error is rejected and rolled back",
       %{owner_id: owner_id} do
    capture_log(fn ->
      assert_raise ArgumentError, ~r/must return \{:ok, _\} or \{:error, _\}/, fn ->
        BadReturn.call(%{owner_id: owner_id})
      end
    end)

    assert count("test_carts") == 0
  end

  test "validation happens before the transaction and never touches the database" do
    assert {:error, %Error{code: :validation_failed}} = Atomic.call(%{})
    assert count("test_carts") == 0
  end

  test "the transaction is configurable per command" do
    # No `repo:` means the configured repo, resolved when the command runs.
    assert Atomic.__cmd_repo__() == DDD.TestRepo
    assert Raises.__cmd_repo__() == DDD.TestRepo
    assert NotAtomic.__cmd_repo__() == nil
  end

  test "without a configured repo the error says how to configure one" do
    original = Application.fetch_env!(:vicander, :repo)
    Application.delete_env(:vicander, :repo)
    on_exit(fn -> Application.put_env(:vicander, :repo, original) end)

    assert_raise ArgumentError, ~r/config :vicander, repo: MyApp.Repo/, fn ->
      Atomic.__cmd_repo__()
    end

    # A command that names its repo, or has no transaction, needs no configuration.
    assert Raises.__cmd_repo__() == DDD.TestRepo
    assert NotAtomic.__cmd_repo__() == nil
  end
end
