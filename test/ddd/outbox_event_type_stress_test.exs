defmodule DDD.OutboxEventTypeStressTest do
  @moduledoc """
  What looking up an event type that does not exist costs. A backlog of events of a type that was
  removed is tried again on every attempt, so the lookup runs once per attempt per event.

  The report compares the lookup the poller uses with the listing of every available module that
  it used to use. Timings are machine dependent, so they are printed, not asserted; the test
  asserts only that the lookup is faster than the old one. Run it with

      mix test --only stress test/ddd/outbox_event_type_stress_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :stress

  alias DDD.Outbox.Poller

  @lookups 200

  defp row(n) do
    %{
      id: Ecto.UUID.generate(),
      event_type: "Removed.Event#{n}",
      aggregate_id: "a",
      aggregate_type: "Type.Aggregate",
      payload: %{},
      occurred_at: DateTime.utc_now()
    }
  end

  test "an unknown event type is cheap to reject" do
    rows = for n <- 1..@lookups, do: row(n)

    {now_micros, results} = :timer.tc(fn -> Enum.map(rows, &Poller.build_event/1) end)
    assert Enum.all?(results, &match?({:error, {:unknown_event_module, _}}, &1))

    # What `resolve_module/1` did before: list every module, once per lookup.
    {before_micros, _} =
      :timer.tc(fn ->
        for r <- rows,
            do:
              List.keymember?(
                :code.all_available(),
                String.to_charlist("Elixir." <> r.event_type),
                0
              )
      end)

    modules = length(:code.all_available())

    IO.puts("""

    ── looking up #{@lookups} unknown event types (#{modules} modules available)
      where_is_file : #{Float.round(now_micros / 1000, 1)} ms total, #{Float.round(now_micros / @lookups, 1)} µs each
      all_available : #{Float.round(before_micros / 1000, 1)} ms total, #{Float.round(before_micros / @lookups, 1)} µs each (the previous lookup)
      #{Float.round(before_micros / max(now_micros, 1), 1)}× faster
    """)

    # The size of the gain depends on the machine and what else is running (about 8 to 120 times
    # here), so only its direction is asserted.
    assert now_micros < before_micros
  end
end
