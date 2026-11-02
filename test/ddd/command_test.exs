defmodule DDD.CommandTest do
  use ExUnit.Case, async: true

  defmodule Greet do
    # No database involved here.
    use DDD.Command, transaction: false

    command do
      field :name, :string, required: true
      field :notes, :string, default: nil
    end

    @impl DDD.Command
    def execute(%__MODULE__{name: "nobody"}), do: {:error, {:unknown_person, "who?"}}

    def execute(%__MODULE__{name: "broken"}),
      do: {:error, DDD.Error.new(code: :broken, context: %{a: 1})}

    def execute(%__MODULE__{name: name}), do: {:ok, "hello #{name}"}
  end

  describe "new/1" do
    test "creates a command and applies defaults" do
      assert {:ok, %Greet{name: "Ann", notes: nil}} = Greet.new(%{name: "Ann"})
    end

    test "accepts a keyword list" do
      assert {:ok, %Greet{name: "Ann"}} = Greet.new(name: "Ann")
    end

    test "returns a DDD.Error for missing required fields" do
      assert {:error, %DDD.Error{} = error} = Greet.new(%{})
      assert error.entity == Greet
      assert error.operation == :new
      assert DDD.Error.to_map(error) == %{name: ["is required"]}
    end

    test "a nil required field counts as missing" do
      assert {:error, error} = Greet.new(name: nil)
      assert DDD.Error.codes(error) == [:required]
    end
  end

  describe "call/1" do
    test "runs the handler for a command struct" do
      assert {:ok, "hello Ann"} = Greet.call(%Greet{name: "Ann"})
    end

    test "builds the command from attrs first" do
      assert {:ok, "hello Ann"} = Greet.call(%{name: "Ann"})
      assert {:ok, "hello Ann"} = Greet.call(name: "Ann")
    end

    test "invalid attrs never reach the handler, and the error names the command" do
      assert {:error, %DDD.Error{code: :validation_failed, context: context}} = Greet.call(%{})
      assert context == %{command: Greet}
    end

    test "handler errors become DDD.Errors with the command in the context" do
      assert {:error, %DDD.Error{code: :unknown_person, message: "who?", context: context}} =
               Greet.call(%{name: "nobody"})

      assert context == %{command: Greet}
    end

    test "existing error context is kept" do
      assert {:error, %DDD.Error{context: %{a: 1, command: Greet}}} =
               Greet.call(%{name: "broken"})
    end
  end

  describe "call!/1" do
    test "returns the value or raises" do
      assert Greet.call!(%{name: "Ann"}) == "hello Ann"

      assert_raise RuntimeError, ~r/Command .*Greet failed/, fn ->
        Greet.call!(%{name: "nobody"})
      end
    end
  end
end
