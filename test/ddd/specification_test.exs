defmodule DDD.SpecificationTest do
  use ExUnit.Case, async: true

  import DDD.Specification

  defmodule Positive do
    use DDD.Specification, field: :n

    def check(%{n: n}, _opts) when n > 0, do: :ok
    def check(%{n: n}, _opts), do: {:error, :not_positive, "must be positive", %{n: n}}
  end

  defmodule Small do
    use DDD.Specification

    def check(%{n: n}, opts) do
      max = Keyword.get(opts, :max, 10)
      if n <= max, do: :ok, else: {:error, :too_big, "must be at most #{max}"}
    end
  end

  test "satisfied_by?/2 is derived from check/2" do
    assert Positive.satisfied_by?(%{n: 1})
    refute Positive.satisfied_by?(%{n: 0})
    assert Small.satisfied_by?(%{n: 50}, max: 100)
    refute Small.satisfied_by?(%{n: 50})
  end

  describe "evaluate/3" do
    test "reports field, code, message and details" do
      assert {:error,
              %{field: :n, code: :not_positive, message: "must be positive", details: %{n: 0}}} =
               evaluate(Positive, %{n: 0})
    end

    test "defaults the field to :base and details to an empty map" do
      assert {:error, %{field: :base, code: :too_big, details: %{}}} = evaluate(Small, %{n: 11})
    end

    test "passes options to check/2, from a {module, opts} pair or directly" do
      assert :ok = evaluate({Small, max: 20}, %{n: 15})
      assert :ok = evaluate(Small, %{n: 15}, max: 20)
      assert {:error, %{code: :too_big}} = evaluate({Small, max: 5}, %{n: 15})
    end
  end

  describe "composition" do
    test "all_of requires every spec and returns the first failure" do
      spec = all_of([Positive, Small])
      assert :ok = evaluate(spec, %{n: 5})
      assert {:error, %{code: :not_positive}} = evaluate(spec, %{n: -1})
      assert {:error, %{code: :too_big}} = evaluate(spec, %{n: 50})
    end

    test "any_of needs one spec and returns the last failure when all fail" do
      spec = any_of([Positive, {Small, max: -5}])
      assert :ok = evaluate(spec, %{n: 5})
      assert :ok = evaluate(spec, %{n: -10})
      assert {:error, %{code: :too_big}} = evaluate(spec, %{n: 0})
    end

    test "any_of with no specs fails" do
      assert {:error, %{code: :no_spec_satisfied}} = evaluate(any_of([]), %{n: 1})
    end

    test "not_spec inverts a spec" do
      assert :ok = evaluate(not_spec(Positive), %{n: -1})
      assert {:error, %{code: :negated_spec_satisfied}} = evaluate(not_spec(Positive), %{n: 1})
    end

    test "composites nest" do
      spec = all_of([Positive, not_spec(any_of([{Small, max: 2}, {Small, max: 3}]))])
      assert :ok = evaluate(spec, %{n: 5})
      assert {:error, _} = evaluate(spec, %{n: 1})
    end
  end
end
