defmodule DDD.OutboxEventTypeTest do
  @moduledoc """
  How the poller turns the event type stored in an outbox row back into a module: a module that
  exists is found, one that does not is an error for that event only, and the lookup of an
  unknown name never creates an atom or touches the file system outside the code path.
  """
  use ExUnit.Case, async: true

  alias DDD.Outbox.Poller

  defmodule Known do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :n, :integer
    end
  end

  defp row(event_type) do
    %{
      id: Ecto.UUID.generate(),
      event_type: event_type,
      aggregate_id: "a",
      aggregate_type: "Type.Aggregate",
      payload: %{"n" => 1},
      occurred_at: DateTime.utc_now()
    }
  end

  test "a module that exists is rebuilt from its row" do
    assert {:ok, %Known{n: 1, aggregate_id: "a"}} =
             Poller.build_event(row("DDD.OutboxEventTypeTest.Known"))
  end

  test "an unknown event type is an error for that event" do
    assert {:error, {:unknown_event_module, "Nope.NoSuchEvent"}} =
             Poller.build_event(row("Nope.NoSuchEvent"))
  end

  test "an unknown name does not create an atom" do
    name = "Nope.NeverSeen#{System.unique_integer([:positive])}"

    assert {:error, {:unknown_event_module, ^name}} = Poller.build_event(row(name))

    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
  end

  for odd <- ["../../etc/passwd", "Foo/Bar", "Foo Bar", "", "Foo..Bar", ".Foo", "1Foo"] do
    test "#{inspect(odd)} is not looked up as a file" do
      assert {:error, {:unknown_event_module, unquote(odd)}} =
               Poller.build_event(row(unquote(odd)))
    end
  end
end
