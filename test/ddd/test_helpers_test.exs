defmodule DDD.TestHelpersTest do
  # Not async: draining the outbox uses the poller, which has a global name.
  use DDD.DataCase

  import DDD.Test

  defmodule Opened do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :subject, :string
    end
  end

  defmodule Closed do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :subject, :string
    end
  end

  defmodule Case do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :owner_id, :uuid, required: true
      field :name, :string, required: true
    end

    defop open(kase), do: emit_event(kase, Opened.new(%{subject: kase.name}))
  end

  defmodule Spy do
    @moduledoc false
    use DDD.EventHandler, events: [DDD.TestHelpersTest.Opened], transaction: false

    @impl DDD.EventHandler
    def handle(event) do
      send(:persistent_term.get({__MODULE__, :pid}), {:handled, event.subject})
      :ok
    end
  end

  defmodule CaseRepository do
    @moduledoc false
    use DDD.Repository

    repo Case do
    end
  end

  defmodule PgCaseRepository do
    @moduledoc false
    use DDD.Repository.Ecto,
      port: DDD.TestHelpersTest.CaseRepository,
      repo: DDD.TestRepo,
      table: "test_carts"
  end

  setup do
    {:ok, kase} = Case.new(owner_id: Ecto.UUID.generate(), name: "billing")
    {:ok, opened} = Case.open(kase)
    %{opened: opened, fresh: kase}
  end

  describe "events" do
    test "emitted_events/1 lists the pending events", %{opened: opened, fresh: fresh} do
      assert [%Opened{subject: "billing"}] = emitted_events(opened)
      assert emitted_events(fresh) == []
    end

    test "assert_event_emitted/3 returns the event, optionally matching fields", %{opened: opened} do
      assert %Opened{subject: "billing"} = assert_event_emitted(opened, Opened)
      assert %Opened{} = assert_event_emitted(opened, Opened, subject: "billing")
    end

    test "assert_event_emitted/3 explains what it found instead", %{opened: opened, fresh: fresh} do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_event_emitted(opened, Closed)
        end

      assert error.message =~ "to have emitted DDD.TestHelpersTest.Closed"
      assert error.message =~ "but it emitted"
      assert error.message =~ "Opened"

      assert_raise ExUnit.AssertionError, ~r/with \[subject: "other"\]/, fn ->
        assert_event_emitted(opened, Opened, subject: "other")
      end

      assert_raise ExUnit.AssertionError, ~r/emitted: \[\]/, fn ->
        assert_event_emitted(fresh, Opened)
      end
    end

    test "refute_event_emitted/3", %{opened: opened} do
      assert :ok = refute_event_emitted(opened, Closed)
      assert :ok = refute_event_emitted(opened, Opened, subject: "other")

      assert_raise ExUnit.AssertionError, ~r/expected no/, fn ->
        refute_event_emitted(opened, Opened)
      end
    end
  end

  describe "assert_error_code/2" do
    test "returns the error when it has the code, its own or a violation's" do
      assert {:error, error} = Case.new(%{})
      assert ^error = assert_error_code({:error, error}, :required)
      assert ^error = assert_error_code({:error, error}, :required)

      single = DDD.Error.business(code: :nope, message: "no")
      assert ^single = assert_error_code({:error, single}, :nope)
    end

    test "explains the codes it found, or that it got something else" do
      assert {:error, error} = Case.new(%{})

      assert_raise ExUnit.AssertionError, ~r/code :other, got: \[:required, :required\]/, fn ->
        assert_error_code({:error, error}, :other)
      end

      assert_raise ExUnit.AssertionError, ~r/expected \{:error, %DDD.Error\{\}\}/, fn ->
        assert_error_code({:ok, 1}, :required)
      end
    end
  end

  describe "drain_outbox/1" do
    setup do
      :persistent_term.put({Spy, :pid}, self())
      on_exit(fn -> :persistent_term.erase({Spy, :pid}) end)

      stop_supervised(DDD.EventBus)
      :ok = Supervisor.terminate_child(DDD.TestSupervisor, DDD.EventBus)
      on_exit(fn -> Supervisor.restart_child(DDD.TestSupervisor, DDD.EventBus) end)

      start_supervised!({DDD.Supervisor, handlers: [Spy], poller: [interval_ms: 600_000]})

      :ok
    end

    test "delivers what the repository saved to the handlers, now", %{opened: opened} do
      {:ok, _} = PgCaseRepository.save(opened)
      refute_received {:handled, _}

      assert drain_outbox() == 1
      assert_received {:handled, "billing"}

      # Nothing left.
      assert drain_outbox() == 0
    end

    test "gives up after the given number of rounds" do
      assert drain_outbox(0) == 0
    end
  end
end
