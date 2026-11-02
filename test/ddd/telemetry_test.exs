defmodule DDD.TelemetryTest do
  use DDD.DataCase

  @moduletag :capture_log

  alias DDD.Outbox.Poller

  defmodule Ping do
    use DDD.DomainEvent

    domain_event do
      field :n, :integer
    end
  end

  # What the handler does is set by the test: `:ok` or a result to return.
  defmodule Handler do
    use DDD.EventHandler, events: [DDD.TelemetryTest.Ping]

    @impl DDD.EventHandler
    def handle(_event), do: :persistent_term.get({__MODULE__, :behaviour}, :ok)
  end

  defmodule Ok do
    use DDD.Command, transaction: false

    command do
      field :n, :integer
    end

    @impl DDD.Command
    def execute(_command), do: {:ok, 1}
  end

  defmodule Business do
    use DDD.Command, transaction: false

    command do
      field :n, :integer
    end

    @impl DDD.Command
    def execute(_command), do: {:error, DDD.Error.business(code: :nope, message: "no")}
  end

  defmodule Infra do
    use DDD.Command, transaction: false

    command do
      field :n, :integer
    end

    @impl DDD.Command
    def execute(_command), do: {:error, DDD.Error.infrastructure(code: :boom, message: "boom")}
  end

  defmodule Crash do
    use DDD.Command, transaction: false

    command do
      field :n, :integer
    end

    @impl DDD.Command
    def execute(_command), do: raise("kaboom")
  end

  defmodule Read do
    use DDD.Query, transaction: false

    query do
      field :mode, :atom
    end

    @impl DDD.Query
    def execute(%{mode: :ok}), do: {:ok, [1]}
    def execute(%{mode: :error}), do: {:error, DDD.Error.business(code: :hidden, message: "no")}
    def execute(%{mode: :crash}), do: raise("kaboom")
  end

  defmodule FakeProjection do
    def lag, do: %{pending: 2, oldest_pending_age_ms: 5}
  end

  defp attach(events) do
    ref = make_ref()
    parent = self()
    id = "telemetry-test-#{inspect(ref)}"

    :telemetry.attach_many(
      id,
      events,
      fn name, measurements, metadata, _ -> send(parent, {ref, name, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  defp insert_event(opts \\ []) do
    id = UUID.uuid4()
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    Repo.insert_all("domain_events", [
      %{
        id: Ecto.UUID.dump!(id),
        event_type: "DDD.TelemetryTest.Ping",
        aggregate_id: "agg-1",
        aggregate_type: "My.Aggregate",
        payload: %{"n" => 1},
        occurred_at: occurred_at,
        inserted_at: DateTime.utc_now(),
        failed_at: opts[:failed_at],
        resolved_at: opts[:resolved_at]
      }
    ])

    id
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  describe "catalogue" do
    test "events/0 lists every event once, spans expanded" do
      events = DDD.Telemetry.events()

      assert events == Enum.uniq(events)
      assert Enum.all?(events, &(is_list(&1) and Enum.all?(&1, fn part -> is_atom(part) end)))
      assert [:ddd, :command, :start] in events
      assert [:ddd, :query, :exception] in events
      assert [:ddd, :outbox, :dead_letter] in events
      assert [:ddd, :projection, :lag] in events
    end
  end

  describe "commands and queries" do
    test "a command is a span, with the result and the error on the stop event" do
      ref = attach([[:ddd, :command, :start], [:ddd, :command, :stop]])

      assert {:ok, 1} = Ok.call(%{})
      assert_received {^ref, [:ddd, :command, :start], _, %{command: Ok}}
      assert_received {^ref, [:ddd, :command, :stop], %{duration: d}, %{command: Ok, result: :ok}}
      assert d > 0

      assert {:error, _} = Business.call(%{})

      assert_received {^ref, [:ddd, :command, :stop], _,
                       %{
                         command: Business,
                         result: :error,
                         error_kind: :business,
                         error_codes: [:nope]
                       }}

      assert {:error, _} = Infra.call(%{})

      assert_received {^ref, [:ddd, :command, :stop], _,
                       %{command: Infra, error_kind: :infrastructure, error_codes: [:boom]}}
    end

    test "a command that crashes emits an exception event and still crashes" do
      ref = attach([[:ddd, :command, :exception]])
      assert_raise RuntimeError, "kaboom", fn -> Crash.call(%{}) end
      assert_received {^ref, [:ddd, :command, :exception], _, %{command: Crash, kind: :error}}
    end

    test "a command that is invalid never starts (no span)" do
      ref = attach([[:ddd, :command, :start]])
      assert {:error, _} = Ok.call(%{n: "not a number"})
      refute_received {^ref, _, _, _}
    end

    test "a query is a span too" do
      ref = attach([[:ddd, :query, :stop], [:ddd, :query, :exception]])

      assert {:ok, [1]} = Read.call(%{mode: :ok})
      assert_received {^ref, [:ddd, :query, :stop], %{duration: _}, %{query: Read, result: :ok}}

      assert {:error, _} = Read.call(%{mode: :error})

      assert_received {^ref, [:ddd, :query, :stop], _,
                       %{result: :error, error_kind: :business, error_codes: [:hidden]}}

      assert_raise RuntimeError, fn -> Read.call(%{mode: :crash}) end
      assert_received {^ref, [:ddd, :query, :exception], _, %{query: Read}}
    end

    test "result_metadata/1 describes any shape of result" do
      assert DDD.Telemetry.result_metadata({:ok, 1}) == %{result: :ok}
      assert DDD.Telemetry.result_metadata(:something_else) == %{result: :ok}

      assert %{result: :error, error_kind: :business, error_codes: [], reason: :plain} =
               DDD.Telemetry.result_metadata({:error, :plain})
    end
  end

  describe "the outbox" do
    setup do
      :persistent_term.erase({Handler, :behaviour})
      Handler.subscribe()
      on_exit(fn -> Handler.unsubscribe() end)

      start_supervised!(
        {Poller, [repo: Repo, interval_ms: 600_000, max_retries: 1, backoff_ms: fn _ -> 0 end]}
      )

      :ok
    end

    test "a delivered event reports the poll, the delivery and how long it waited" do
      ref =
        attach([
          [:ddd, :outbox, :poll],
          [:ddd, :outbox, :published],
          [:ddd, :handler, :deliver, :stop]
        ])

      insert_event(occurred_at: ago(3600))
      assert {:ok, 1} = Poller.poll_now()

      assert_received {^ref, [:ddd, :outbox, :poll], %{claimed: 1}, _}

      assert_received {^ref, [:ddd, :handler, :deliver, :stop], %{duration: _},
                       %{handler: Handler, event: Ping, outcome: :delivered}}

      assert_received {^ref, [:ddd, :outbox, :published], %{count: 1, delay_ms: delay},
                       %{event_type: "DDD.TelemetryTest.Ping"}}

      assert delay >= 3_600_000
    end

    test "an empty poll still reports" do
      ref = attach([[:ddd, :outbox, :poll]])
      assert {:ok, 0} = Poller.poll_now()
      assert_received {^ref, [:ddd, :outbox, :poll], %{claimed: 0}, _}
    end

    test "a failing delivery is reported as a retry, then as a dead letter" do
      :persistent_term.put(
        {Handler, :behaviour},
        {:error, DDD.Error.infrastructure(code: :down, message: "down")}
      )

      ref =
        attach([
          [:ddd, :outbox, :retry],
          [:ddd, :outbox, :dead_letter],
          [:ddd, :handler, :deliver, :stop]
        ])

      insert_event()

      assert {:ok, 1} = Poller.poll_now()

      assert_received {^ref, [:ddd, :handler, :deliver, :stop], _, %{outcome: :error}}

      assert_received {^ref, [:ddd, :outbox, :retry], %{attempts: 1, delay_ms: 0},
                       %{event_type: "DDD.TelemetryTest.Ping", error: error}}

      assert error =~ "down"
      refute_received {^ref, [:ddd, :outbox, :dead_letter], _, _}

      assert {:ok, 1} = Poller.poll_now()

      assert_received {^ref, [:ddd, :outbox, :dead_letter], %{attempts: 2},
                       %{aggregate_id: "agg-1"}}
    end

    test "a rejection is a rejected delivery, not a retry" do
      :persistent_term.put({Handler, :behaviour}, {:error, :not_for_us})
      ref = attach([[:ddd, :outbox, :retry], [:ddd, :handler, :deliver, :stop]])

      insert_event()
      assert {:ok, 1} = Poller.poll_now()

      assert_received {^ref, [:ddd, :handler, :deliver, :stop], _, %{outcome: :rejected}}
      refute_received {^ref, [:ddd, :outbox, :retry], _, _}
    end
  end

  describe "outbox_stats/1" do
    test "is all zeros on an empty outbox" do
      assert DDD.Telemetry.outbox_stats(Repo) ==
               %{pending: 0, in_flight: 0, dead_letters: 0, oldest_pending_age_ms: 0}
    end

    test "counts what waits, what is being delivered, and what was given up on" do
      insert_event(occurred_at: ago(600))
      insert_event(occurred_at: ago(300))
      insert_event(failed_at: DateTime.utc_now())
      # A dead letter someone has dealt with no longer counts.
      insert_event(failed_at: DateTime.utc_now(), resolved_at: DateTime.utc_now())

      # Claims the oldest one: it is now in flight (and still pending).
      assert [_] = Poller.claim(Repo, 1, 60_000)

      assert %{pending: 2, in_flight: 1, dead_letters: 1, oldest_pending_age_ms: age} =
               DDD.Telemetry.outbox_stats(Repo)

      # Inside the test's sandbox transaction `now()` is the moment the transaction began, which
      # is a little before this event's timestamp was taken, so the age can read slightly short.
      assert age >= 590_000 and age < 700_000
    end
  end

  describe "report/2" do
    test "emits the outbox gauges and a lag gauge for each projection" do
      ref = attach([[:ddd, :outbox, :stats], [:ddd, :projection, :lag]])
      insert_event(occurred_at: ago(10))

      assert %{pending: 1} = DDD.Telemetry.report(Repo, [FakeProjection])

      assert_received {^ref, [:ddd, :outbox, :stats], %{pending: 1, dead_letters: 0}, %{}}

      assert_received {^ref, [:ddd, :projection, :lag], %{pending: 2, oldest_pending_age_ms: 5},
                       %{projection: FakeProjection}}
    end

    test "without projections it reports only the outbox" do
      ref = attach([[:ddd, :outbox, :stats], [:ddd, :projection, :lag]])
      DDD.Telemetry.report(Repo)
      assert_received {^ref, [:ddd, :outbox, :stats], _, _}
      refute_received {^ref, [:ddd, :projection, :lag], _, _}
    end
  end
end
