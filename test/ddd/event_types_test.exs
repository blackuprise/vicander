defmodule DDD.EventTypesTest do
  @moduledoc """
  An event keeps the types of its fields through the outbox: what is stored is JSON, and what the
  handler gets is the event as it was emitted (an atom is an atom, a Decimal a Decimal).
  """
  use DDD.DataCase

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias DDD.DomainEvent
  alias DDD.Outbox.Poller

  defmodule Typed do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :label, :string
      field :count, :integer
      field :status, :atom
      field :state, {:enum, [:open, :closed]}
      field :amount, :decimal
      field :due, :date
      field :at, :datetime
      field :meta, :map, default: %{}
    end
  end

  @emitted %{
    label: "a",
    count: 3,
    status: :pending,
    state: :open,
    amount: Decimal.new("12.50"),
    due: ~D[2026-11-11],
    at: ~U[2026-11-11 10:20:30.123456Z],
    meta: %{"k" => 1}
  }

  defp row(payload, type \\ "DDD.EventTypesTest.Typed") do
    %{
      id: Ecto.UUID.generate(),
      event_type: type,
      aggregate_id: "a1",
      aggregate_type: "Typed.Aggregate",
      payload: payload,
      occurred_at: DateTime.utc_now()
    }
  end

  defp stored(event),
    do: event |> DomainEvent.dump_payload() |> Jason.encode!() |> Jason.decode!()

  describe "the stored payload" do
    test "holds every typed field as plain JSON" do
      payload = stored(Typed.new(@emitted))

      assert payload["status"] == "pending"
      assert payload["state"] == "open"
      assert payload["amount"] == "12.50"
      assert payload["due"] == "2026-11-11"
      assert payload["at"] == "2026-11-11T10:20:30.123456Z"
      assert payload["count"] == 3
      assert payload["meta"] == %{"k" => 1}
    end

    test "leaves a value that does not fit its type as it is" do
      # A date given as text is already what would be stored.
      payload = stored(Typed.new(%{@emitted | due: "2026-11-11"}))
      assert payload["due"] == "2026-11-11"
    end
  end

  describe "the event a handler gets" do
    test "has the types it was emitted with" do
      assert {:ok, event} = @emitted |> Typed.new() |> stored() |> row() |> Poller.build_event()

      assert event.status == :pending
      assert event.state == :open
      assert Decimal.equal?(event.amount, Decimal.new("12.50"))
      assert event.due == ~D[2026-11-11]
      assert event.at == ~U[2026-11-11 10:20:30.123456Z]
      assert event.count == 3
      assert event.meta == %{"k" => 1}
    end

    test "keeps the stored value of a field that does not load, and says so" do
      payload = %{"amount" => "twelve", "due" => "2026-11-11", "status" => "pending"}

      log =
        capture_log(fn ->
          assert {:ok, event} = payload |> row() |> Poller.build_event()
          assert event.amount == "twelve"
          # The others still load.
          assert event.due == ~D[2026-11-11]
          assert event.status == :pending
        end)

      assert log =~ "DDD.EventTypesTest.Typed.amount"
      assert log =~ "keeping it as stored"
    end

    test "loads a row written before its fields had types, and drops fields it no longer has" do
      payload = %{"label" => "old", "removed_since" => "x"}

      assert {:ok, event} = payload |> row() |> Poller.build_event()
      assert event.label == "old"
      assert event.amount == nil
      assert event.meta == %{}
    end

    test "does not fail on a nil value" do
      assert {:ok, %{amount: nil, due: nil}} =
               %{"amount" => nil, "due" => nil} |> row() |> Poller.build_event()
    end
  end

  # ── Through the outbox table ──────────────────────────────────────────────

  defmodule Thing do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :name, :string, required: true
    end

    defop emit(thing) do
      emit_event(
        thing,
        DDD.EventTypesTest.Typed.new(%{
          status: :pending,
          amount: Decimal.new("0.10"),
          due: ~D[2030-01-02]
        })
      )
    end
  end

  defmodule ThingPort do
    @moduledoc false
    use DDD.Repository

    repo Thing do
    end
  end

  defmodule Things do
    @moduledoc false
    use DDD.Repository.Ecto, port: ThingPort, repo: DDD.TestRepo, table: "typed_things"
  end

  test "an event saved with its aggregate comes back from the outbox with its types" do
    Repo.query!("""
    CREATE TEMP TABLE typed_things (
      id uuid PRIMARY KEY, name varchar,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    {:ok, thing} = Thing.new(name: "t")
    {:ok, thing} = Thing.emit(thing)
    {:ok, _} = Things.save(thing)

    fields = DDD.Outbox.Event.delivery_fields()
    [row] = Repo.all(from(e in DDD.Outbox.Event, select: map(e, ^fields)))

    assert row.payload["status"] == "pending"
    assert row.payload["amount"] == "0.10"

    assert {:ok, event} = Poller.build_event(row)
    assert event.status == :pending
    assert Decimal.equal?(event.amount, Decimal.new("0.10"))
    assert event.due == ~D[2030-01-02]
  end
end
