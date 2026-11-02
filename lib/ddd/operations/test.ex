defmodule DDD.Test do
  @moduledoc """
  Helpers for testing an application built on the framework.

      use ExUnit.Case
      import DDD.Test

      test "completing the last item finishes the list" do
        {:ok, list} = TodoList.complete_item(list, item.id)

        assert_event_emitted(list, ItemCompleted, item_id: item.id)
        refute_event_emitted(list, ListReopened)
      end

      test "a failure says why" do
        assert_error_code(TodoList.complete_item(list, item.id), :already_completed)
      end

      test "the handlers ran" do
        {:ok, _} = Commands.AddItem.call(...)
        drain_outbox()
        assert ... # the handlers' effects
      end

  Pending events are the ones an aggregate has emitted and not yet saved. Once a repository
  saves it they are in the outbox; `drain_outbox/1` delivers them to the subscribed handlers.
  """

  @doc "The events an aggregate has emitted and not yet saved."
  @spec emitted_events(struct()) :: [struct()]
  def emitted_events(%{__pending_events__: events}), do: events

  @doc """
  Assert that `aggregate` emitted an event of the `event` module, optionally with these field
  values. Returns the first matching event.
  """
  @spec assert_event_emitted(struct(), module(), keyword()) :: struct()
  def assert_event_emitted(aggregate, event, fields \\ []) do
    case Enum.find(emitted_events(aggregate), &matches?(&1, event, fields)) do
      nil ->
        fail(
          "expected #{inspect(aggregate.__struct__)} to have emitted #{describe(event, fields)}, " <>
            "but it emitted: #{inspect(Enum.map(emitted_events(aggregate), &summary/1))}"
        )

      found ->
        found
    end
  end

  @doc "Assert that `aggregate` did not emit such an event."
  @spec refute_event_emitted(struct(), module(), keyword()) :: :ok
  def refute_event_emitted(aggregate, event, fields \\ []) do
    case Enum.find(emitted_events(aggregate), &matches?(&1, event, fields)) do
      nil -> :ok
      found -> fail("expected no #{describe(event, fields)} but found: #{inspect(found)}")
    end
  end

  @doc """
  Assert that a result is `{:error, %DDD.Error{}}` that has `code` (its own, or one of its
  violations'). Returns the error, so more can be asserted about it.
  """
  @spec assert_error_code(term(), atom()) :: DDD.Error.t()
  def assert_error_code({:error, %DDD.Error{} = error}, code) do
    if DDD.Error.has_code?(error, code),
      do: error,
      else:
        fail(
          "expected an error with code #{inspect(code)}, got: #{inspect(DDD.Error.codes(error))}"
        )
  end

  def assert_error_code(other, code),
    do: fail("expected {:error, %DDD.Error{}} with code #{inspect(code)}, got: #{inspect(other)}")

  @doc """
  Deliver every event waiting in the outbox to the subscribed handlers, now, instead of waiting
  for the poller's timer. Needs the poller to be running (`DDD.Supervisor` starts it, with
  `poller: [interval_ms: 600_000]` to keep it from polling by itself in tests). Events that
  handlers produce while handling are delivered too. Returns how many events were delivered.
  """
  @spec drain_outbox(non_neg_integer()) :: non_neg_integer()
  def drain_outbox(max_rounds \\ 20), do: drain(max_rounds, 0)

  defp drain(0, total), do: total

  defp drain(rounds, total) do
    case DDD.Outbox.Poller.poll_now() do
      {:ok, 0} -> total
      {:ok, claimed} -> drain(rounds - 1, total + claimed)
    end
  end

  defp matches?(event, module, fields) do
    is_struct(event, module) and
      Enum.all?(fields, fn {key, value} -> Map.get(event, key) == value end)
  end

  defp describe(event, []), do: inspect(event)
  defp describe(event, fields), do: "#{inspect(event)} with #{inspect(fields)}"

  defp summary(%{__struct__: module} = event), do: {module, Map.drop(event, [:__struct__])}
  defp summary(other), do: other

  # ExUnit is the test framework of whoever calls this, so it is looked up when needed.
  defp fail(message), do: raise(ExUnit.AssertionError, message: message)
end
