defmodule Mix.Tasks.Vic.McpTest do
  # Not async: the task changes the Mix shell, the logger handler and the application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Vic.Mcp

  setup do
    shell = Mix.shell()
    repo_env = Application.get_env(:vicander, DDD.TestRepo)
    poller = Application.get_env(:vicander, :start_outbox_poller)

    on_exit(fn ->
      Mix.shell(shell)
      Application.put_env(:vicander, DDD.TestRepo, repo_env)
      Application.put_env(:vicander, :start_outbox_poller, poller)
      Mcp.route_logger(:standard_io)
    end)
  end

  test "it needs exactly one server module" do
    assert_raise Mix.Error, ~r/usage: mix vic.mcp/, fn -> Mcp.run([]) end
    assert_raise Mix.Error, ~r/usage: mix vic.mcp/, fn -> Mcp.run(["A", "B"]) end
  end

  test "it refuses a module that is not a server" do
    assert_raise Mix.Error, ~r/is not a DDD.MCP.Server module/, fn -> Mcp.run(["Enum"]) end

    assert_raise Mix.Error, ~r/is not a DDD.MCP.Server module/, fn ->
      Mcp.run(["No.Such.Module"])
    end
  end

  test "it serves the module on stdin and stdout, and only protocol goes to stdout" do
    input = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"}\n)

    output = capture_io([input: input], fn -> Mcp.run(["DDD.Test.MCPServer"]) end)

    assert [line] = String.split(output, "\n", trim: true)
    names = line |> Jason.decode!() |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])
    assert Enum.sort(names) == ["greet", "lookup"]
  end

  test "--read-only leaves only the queries" do
    input = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"}\n)

    output =
      capture_io([input: input], fn -> Mcp.run(["DDD.Test.MCPServer", "--read-only"]) end)

    names = output |> Jason.decode!() |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])

    assert names == ["lookup"]
  end

  test "it turns the SQL log off and leaves the outbox poller setting alone" do
    Application.put_env(:vicander, :start_outbox_poller, true)

    capture_io([input: ""], fn -> Mcp.run(["DDD.Test.MCPServer"]) end)

    assert Application.get_env(:vicander, DDD.TestRepo)[:log] == false
    assert Application.get_env(:vicander, :start_outbox_poller) == true
  end

  test "it moves the logger to standard error, so logs can't corrupt the protocol" do
    capture_io([input: ""], fn -> Mcp.run(["DDD.Test.MCPServer"]) end)

    assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)
  end
end
