defmodule DDD.SensitiveFieldsTest do
  @moduledoc """
  A field marked `sensitive: true` is left out of `inspect/1`, and so out of the framework's debug
  logs, while it stays in the struct and reaches the code that needs it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  # The modules are in test/support: see the note there.
  alias DDD.Test.Sensitive.{Lookup, Paid, Plain, Register}

  @secret "hunter2-the-secret"

  describe "a command" do
    test "does not show the field when inspected, and shows the others" do
      {:ok, command} = Register.new(email: "a@b.c", password: @secret)

      text = inspect(command)
      refute text =~ @secret
      refute text =~ "password"
      assert text =~ "a@b.c"
    end

    test "still has the value, which reaches execute/1" do
      {:ok, command} = Register.new(email: "a@b.c", password: @secret)

      assert command.password == @secret
      assert {:ok, 18} = Register.call(command)
    end

    test "is still validated" do
      assert {:error, error} = Register.new(email: "a@b.c")
      assert [%{field: :password, code: :required}] = error.violations
    end

    test "keeps the value out of the debug log" do
      log =
        capture_log([level: :debug], fn -> Register.call(email: "a@b.c", password: @secret) end)

      assert log =~ "started"
      assert log =~ "a@b.c"
      refute log =~ @secret
    end

    test "without a sensitive field is inspected in full" do
      {:ok, command} = Plain.new(note: "visible")
      assert inspect(command) =~ "visible"
    end
  end

  describe "a query" do
    test "keeps the value out of inspect and the debug log" do
      {:ok, query} = Lookup.new(email: "a@b.c", token: @secret)
      refute inspect(query) =~ @secret

      log = capture_log([level: :debug], fn -> assert {:ok, @secret} = Lookup.call(query) end)

      assert log =~ "started"
      assert log =~ "a@b.c"
      refute log =~ @secret
    end
  end

  describe "an event" do
    test "does not show the field when inspected" do
      event = Paid.new(%{order_id: "o-1", card: "4111111111111111"})

      refute inspect(event) =~ "4111111111111111"
      assert inspect(event) =~ "o-1"
    end

    test "still has the value, and the stored payload does too" do
      event = Paid.new(%{order_id: "o-1", card: "4111111111111111"})

      assert event.card == "4111111111111111"
      assert DDD.DomainEvent.dump_payload(event).card == "4111111111111111"
    end
  end
end
