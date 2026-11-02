defmodule DDD.ErrorTest do
  use ExUnit.Case, async: true

  alias DDD.Error

  test "new/1 builds an error with defaults" do
    error = Error.new(code: :boom, message: "boom")
    assert %Error{code: :boom, details: %{}, violations: [], context: %{}} = error
  end

  test "validation_failed/3 summarises the violations" do
    violations = [
      Error.violation(:a, :required, "is required"),
      Error.violation(:b, :invalid, "bad")
    ]

    error = Error.validation_failed(__MODULE__, :new, violations)

    assert error.code == :validation_failed
    assert error.entity == __MODULE__
    assert error.operation == :new
    assert error.message =~ "2 violation(s)"
    assert Error.codes(error) == [:required, :invalid]
    assert Error.has_code?(error, :invalid)
    refute Error.has_code?(error, :other)
  end

  test "codes/1 falls back to the top-level code" do
    assert Error.codes(Error.new(code: :not_found)) == [:not_found]
  end

  test "to_map/1 groups messages by field and uses :base without violations" do
    violations = [
      Error.violation(:a, :invalid, "one"),
      Error.violation(:a, :invalid, "two"),
      Error.violation(:b, :invalid, "three")
    ]

    assert Error.to_map(Error.validation_failed(__MODULE__, :new, violations)) ==
             %{a: ["one", "two"], b: ["three"]}

    assert Error.to_map(Error.new(code: :boom, message: "it broke")) == %{base: ["it broke"]}
  end

  describe "kind" do
    test "errors are business errors unless stated otherwise" do
      assert %Error{kind: :business} = Error.new(code: :boom)
      assert %Error{kind: :business} = Error.business(code: :boom)
      assert %Error{kind: :business} = Error.validation_failed(__MODULE__, :new, [])
    end

    test "infrastructure/1 builds an infrastructure error" do
      error = Error.infrastructure(code: :db_down, message: "database is down")
      assert %Error{kind: :infrastructure, code: :db_down} = error
      assert Error.infrastructure?(error)
      refute Error.business?(error)
    end

    test "business/1 overrides a kind passed in" do
      assert %Error{kind: :business} = Error.business(code: :x, kind: :infrastructure)
    end

    test "predicates" do
      assert Error.business?(Error.business(code: :x))
      refute Error.infrastructure?(Error.business(code: :x))
    end

    test "wrap/2 treats a plain reason as the domain's answer: business" do
      assert %Error{kind: :business} = Error.wrap(:not_found, %{})
      assert %Error{kind: :business} = Error.wrap({:taken, "email taken"}, %{})
      assert %Error{kind: :business} = Error.wrap({1, 2, 3}, %{})
    end

    test "wrap/2 turns an exception into an infrastructure error" do
      error = Error.wrap(%RuntimeError{message: "kaboom"}, %{handler: Some.Handler})

      assert %Error{
               kind: :infrastructure,
               code: :exception,
               message: "kaboom",
               details: %{exception: "RuntimeError"},
               context: %{handler: Some.Handler}
             } = error
    end

    test "wrap/2 keeps the kind of an error that is already a DDD.Error" do
      error = Error.infrastructure(code: :db_down)
      assert %Error{kind: :infrastructure} = Error.wrap(error, %{a: 1})
    end
  end

  describe "wrap/2" do
    test "merges context into an existing error" do
      error = Error.new(code: :boom, context: %{a: 1})
      assert %Error{context: %{a: 1, b: 2}} = Error.wrap(error, b: 2)
    end

    test "wraps atoms, {code, message} tuples and anything else" do
      assert %Error{code: :not_found, message: "not_found", context: %{x: 1}} =
               Error.wrap(:not_found, %{x: 1})

      assert %Error{code: :taken, message: "email taken"} =
               Error.wrap({:taken, "email taken"}, %{})

      assert %Error{code: :unknown, details: %{reason: "{1, 2, 3}"}} = Error.wrap({1, 2, 3}, %{})
    end
  end
end
