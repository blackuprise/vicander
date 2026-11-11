defmodule DDD.DescriptionsTest do
  use ExUnit.Case, async: true

  defmodule Thing do
    use DDD.Aggregate

    aggregate do
      description "Something we keep track of"

      identity :id, :uuid
      field :name, :string, required: true, description: "What it is called"
    end

    @doc "Give the thing another name"
    defop rename(thing, name) do
      %{thing | name: name}
    end

    defop plain(thing), do: thing
  end

  defmodule Bare do
    use DDD.ValueObject

    value_object do
      field :x, :integer
    end
  end

  defmodule Order do
    use DDD.Command, transaction: false

    command do
      description "Place an order"
      field :sku, :string, required: true, description: "What to order"
      field :quantity, :integer, default: 1
    end

    def execute(_), do: {:ok, 1}
  end

  test "entities, aggregates and value objects can describe themselves" do
    assert Thing.__ddd_description__() == "Something we keep track of"
    assert Bare.__ddd_description__() == nil
  end

  test "a field's description is kept with the field" do
    {:name, :string, opts} = List.keyfind(Thing.__ddd_fields__(), :name, 0)
    assert opts[:description] == "What it is called"
  end

  test "operations can carry a description; those without don't appear" do
    assert Thing.__ddd_ops__() == [{:rename, 2, "Give the thing another name"}]
  end

  describe "the @doc of a defop" do
    import ExUnit.CaptureIO

    @moduletag :tmp_dir

    # Compile `body` as an aggregate and return {the operations' signatures, the docs the
    # public functions ended up with, what was printed to stderr while compiling}.
    defp compile(dir, body) do
      name = "DDD.DescriptionsTest.Gen#{System.unique_integer([:positive])}"

      source = """
      defmodule #{name} do
        use DDD.Aggregate

        aggregate do
          identity :id, :uuid
          field :name, :string
        end

      #{body}
      end
      """

      # The docs chunk is only written when the compiler is asked for it; tests run without.
      previous = Code.get_compiler_option(:docs)
      Code.put_compiler_option(:docs, true)

      stderr =
        try do
          capture_io(:stderr, fn ->
            send(self(), {:compiled, Code.compile_string(source)})
          end)
        after
          Code.put_compiler_option(:docs, previous)
        end

      assert_received {:compiled, [{module, binary} | _]}
      path = Path.join(dir, "#{module}.beam")
      File.write!(path, binary)
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(path)

      docs_by_op =
        for {{:function, fun, arity}, _, _, doc, _} <- docs, into: %{}, do: {{fun, arity}, doc}

      {module.__ddd_op_signatures__(), docs_by_op, stderr}
    end

    test "is the operation's description and its documentation", %{tmp_dir: dir} do
      {[sig], docs, stderr} =
        compile(dir, """
          @doc "Give it a name"
          defop rename(a, n), do: %{a | name: n}
        """)

      assert sig.description == "Give it a name"
      assert %{"en" => "Give it a name"} = docs[{:rename, 2}]
      assert stderr == ""
    end

    test "is kept whole when it is a heredoc", %{tmp_dir: dir} do
      {[sig], docs, _} =
        compile(dir, ~S'''
          @doc """
          Rename it.

          The new name must not be empty.
          """
          defop rename(a, n), do: %{a | name: n}
        ''')

      assert sig.description == "Rename it.\n\nThe new name must not be empty.\n"
      assert %{"en" => text} = docs[{:rename, 2}]
      assert text =~ "must not be empty"
    end

    test "false hides the operation and gives it no description", %{tmp_dir: dir} do
      {[sig], docs, stderr} =
        compile(dir, """
          @doc false
          defop secret(a), do: a
        """)

      assert sig.description == nil
      assert docs[{:secret, 1}] == :hidden
      assert stderr == ""
    end

    test "on one operation does not leak onto the next", %{tmp_dir: dir} do
      {sigs, docs, _} =
        compile(dir, """
          @doc "First"
          defop one(a), do: a
          defop two(a), do: a
        """)

      assert Enum.map(sigs, & &1.description) == ["First", nil]
      assert docs[{:two, 1}] == :none
    end

    test "description: still works, and is deprecated", %{tmp_dir: dir} do
      {[sig], docs, stderr} =
        compile(dir, """
          defop rename(a, n), description: "Old way" do
            %{a | name: n}
          end
        """)

      assert sig.description == "Old way"
      assert %{"en" => "Old way"} = docs[{:rename, 2}]
      assert stderr =~ "`description:` on defop rename/2 is deprecated"
    end

    test "wins over description:, which is then called redundant", %{tmp_dir: dir} do
      {[sig], _docs, stderr} =
        compile(dir, """
          @doc "From the doc"
          defop rename(a, n), description: "From the option" do
            %{a | name: n}
          end
        """)

      assert sig.description == "From the doc"
      assert stderr =~ "`description:` on defop rename/2 is ignored"
    end
  end

  test "a description changes nothing about how the entity works" do
    {:ok, thing} = Thing.new(name: "a")
    assert {:ok, %{name: "b"}} = Thing.rename(thing, "b")
  end

  test "commands and queries declare their description and parameters" do
    assert Order.__description__() == "Place an order"

    assert [{:sku, :string, sku_opts}, {:quantity, :integer, _}] = Order.__params__()
    assert sku_opts[:description] == "What to order"
    assert sku_opts[:required]
  end

  test "command parameters are type-checked and typos fail at compile time" do
    assert {:ok, %{sku: "a", quantity: 1}} = Order.new(sku: "a")
    assert {:error, error} = Order.new(sku: 5, quantity: "many")
    assert Enum.sort(Enum.map(error.violations, & &1.field)) == [:quantity, :sku]

    assert_raise ArgumentError, ~r/unknown field type/, fn ->
      Code.compile_string("""
      defmodule DDD.DescriptionsTest.Typo do
        use DDD.Command
        command do
          field :x, :strng
        end
      end
      """)
    end
  end
end
