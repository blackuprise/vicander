defmodule DDD.MCPHTTPTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias DDD.MCP.HTTP

  # A hook of three arguments: who is asking decides.
  defmodule Hook do
    @moduledoc false
    def authorize("greet", _arguments, %{user: "ann"}), do: :ok
    def authorize("greet", _arguments, _context), do: {:error, "Only Ann may greet."}
    def authorize(_tool, _arguments, _context), do: :ok
  end

  # A hook of two arguments, as before this transport existed.
  defmodule TwoArgHook do
    @moduledoc false
    def authorize("greet", %{"name" => "nobody"}), do: {:error, "That name is not on the list."}
    def authorize(_tool, _arguments), do: :ok
  end

  defmodule TwoArgServer do
    @moduledoc false
    use DDD.MCP.Server,
      commands: [DDD.Test.Greet],
      queries: [DDD.Test.Lookup],
      authorize: &DDD.MCPHTTPTest.TwoArgHook.authorize/2
  end

  defmodule WhoServer do
    @moduledoc false
    use DDD.MCP.Server,
      commands: [DDD.Test.Greet],
      queries: [DDD.Test.Lookup],
      authorize: &DDD.MCPHTTPTest.Hook.authorize/3
  end

  @metadata "https://shop.example.com/.well-known/oauth-protected-resource/mcp"

  # Tokens the tests accept.
  def authenticate("ann-token"), do: {:ok, %{user: "ann", scopes: ["read", "write"]}}
  def authenticate("bob-token"), do: {:ok, %{user: "bob", scopes: ["read"]}}
  def authenticate(_), do: {:error, :invalid_token}

  # A tool call needs the scope "write" if it is a command.
  def require_scope(%{"method" => "tools/call", "params" => %{"name" => "greet"}}, context) do
    if "write" in context.scopes, do: :ok, else: {:error, {:insufficient_scope, "write"}}
  end

  def require_scope(_message, _context), do: :ok

  defp opts(extra \\ []) do
    HTTP.init(Keyword.merge([server: DDD.Test.MCPServer, authenticate: :none], extra))
  end

  defp secured(extra \\ []) do
    [authenticate: &__MODULE__.authenticate/1, resource_metadata: @metadata]
    |> Keyword.merge(extra)
    |> opts()
  end

  defp rpc(method, params \\ nil, id \\ 1) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    if params, do: Map.put(message, "params", params), else: message
  end

  defp post(opts, body, headers \\ []) do
    body = if is_binary(body), do: body, else: Jason.encode!(body)

    conn = conn(:post, "/mcp", body) |> put_req_header("content-type", "application/json")
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    HTTP.call(conn, opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  describe "configuration" do
    test "needs an `authenticate:`, and `:none` has to be asked for" do
      assert_raise ArgumentError, ~r/needs `authenticate:`/, fn ->
        HTTP.init(server: DDD.Test.MCPServer)
      end

      assert_raise ArgumentError, ~r/needs `authenticate:`/, fn ->
        HTTP.init(server: DDD.Test.MCPServer, authenticate: "nope")
      end

      assert %{authenticate: :none} = HTTP.init(server: DDD.Test.MCPServer, authenticate: :none)
    end
  end

  describe "the transport" do
    test "answers a request with the JSON reply" do
      conn = post(opts(), rpc("tools/list"))

      assert conn.status == 200
      assert header(conn, "content-type") =~ "application/json"
      assert header(conn, "cache-control") == "no-store"
      assert %{"result" => %{"tools" => tools}} = json(conn)
      assert Enum.map(tools, & &1["name"]) == ~w(greet lookup)
    end

    test "calls a tool" do
      call = rpc("tools/call", %{"name" => "lookup", "arguments" => %{"word" => "elixir"}})

      assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
               opts() |> post(call) |> json()

      assert Jason.decode!(text) == %{"word" => "elixir", "length" => 6}
    end

    test "answers a notification with 202 and no body" do
      conn = post(opts(), %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "answers a client's response to a request with 202" do
      conn = post(opts(), %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}})
      assert conn.status == 202

      conn = post(opts(), %{"jsonrpc" => "2.0", "id" => 7, "error" => %{"code" => 1}})
      assert conn.status == 202
    end

    test "an unknown method is a JSON-RPC error in a 200, as the protocol has it" do
      conn = post(opts(), rpc("nope/nope"))
      assert conn.status == 200
      assert %{"error" => %{"code" => -32_601}} = json(conn)
    end

    test "refuses any method but POST" do
      for method <- [:get, :put, :delete] do
        conn = HTTP.call(conn(method, "/mcp"), opts())
        assert conn.status == 405
        assert header(conn, "allow") == "POST"
      end
    end

    test "refuses text that is not JSON, a batch and an empty body" do
      assert %{"error" => %{"code" => -32_700}} = opts() |> post("{nope") |> json()
      assert post(opts(), "{nope").status == 400

      assert post(opts(), "[]").status == 400
      assert post(opts(), Jason.encode!([rpc("ping")])).status == 400
      assert post(opts(), "\"just text\"").status == 400
    end

    test "refuses a body that is too large" do
      big =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping",
          "pad" => String.duplicate("x", 1_100_000)
        })

      assert post(opts(), big).status == 413
    end

    test "takes a body that Plug.Parsers has already read" do
      conn =
        conn(:post, "/mcp")
        |> Map.put(:body_params, rpc("ping"))
        |> then(&HTTP.call(&1, opts()))

      assert conn.status == 200
      assert %{"result" => %{}} = json(conn)

      batch = conn(:post, "/mcp") |> Map.put(:body_params, %{"_json" => [rpc("ping")]})
      assert HTTP.call(batch, opts()).status == 400

      empty = conn(:post, "/mcp") |> Map.put(:body_params, %{})
      assert HTTP.call(empty, opts()).status == 400
    end
  end

  describe "the Origin header" do
    test "is refused unless it is allowed, and a missing one is fine" do
      opts = opts(allowed_origins: ["https://claude.ai"])

      assert post(opts, rpc("ping")).status == 200
      assert post(opts, rpc("ping"), [{"origin", "https://claude.ai"}]).status == 200

      conn = post(opts, rpc("ping"), [{"origin", "https://evil.example"}])
      assert conn.status == 403
      assert %{"error" => %{"message" => "Origin not allowed"}} = json(conn)

      # Nothing is allowed by default: a web page can not drive a local server.
      assert post(opts(), rpc("ping"), [{"origin", "http://localhost:3000"}]).status == 403
    end
  end

  describe "the protocol version header" do
    test "is checked when it is there" do
      assert post(opts(), rpc("ping")).status == 200
      assert post(opts(), rpc("ping"), [{"mcp-protocol-version", "2025-06-18"}]).status == 200

      conn = post(opts(), rpc("ping"), [{"mcp-protocol-version", "1999-01-01"}])
      assert conn.status == 400
    end
  end

  describe "authentication" do
    test "a request without a token gets 401 and says where to log in" do
      conn = post(secured(), rpc("tools/list"))

      assert conn.status == 401
      assert header(conn, "www-authenticate") == ~s(Bearer resource_metadata="#{@metadata}")
    end

    test "so does a token that is not valid, naming the error" do
      conn = post(secured(), rpc("tools/list"), [{"authorization", "Bearer nonsense"}])

      assert conn.status == 401

      assert header(conn, "www-authenticate") ==
               ~s(Bearer error="invalid_token", resource_metadata="#{@metadata}")
    end

    test "and a header that is not a bearer token" do
      for value <- ["Basic abc", "Bearer", "Bearer   ", "ann-token"] do
        conn = post(secured(), rpc("tools/list"), [{"authorization", value}])
        assert conn.status == 401, value
      end
    end

    test "a valid token gets the answer, and the scheme is not case sensitive" do
      for value <- ["Bearer ann-token", "bearer ann-token", "BEARER ann-token"] do
        assert post(secured(), rpc("tools/list"), [{"authorization", value}]).status == 200
      end
    end

    test "the metadata URL can be a function, and may be left out" do
      conn = post(secured(resource_metadata: fn -> "https://x.example/meta" end), rpc("ping"))

      assert header(conn, "www-authenticate") ==
               ~s(Bearer resource_metadata="https://x.example/meta")

      conn = post(secured(resource_metadata: nil), rpc("ping"))
      assert header(conn, "www-authenticate") == "Bearer"
    end

    test "a value can not break out of the header" do
      conn = post(secured(resource_metadata: ~s(https://x.example/"; evil="1)), rpc("ping"))

      assert header(conn, "www-authenticate") ==
               ~s(Bearer resource_metadata="https://x.example/; evil=1")
    end

    test "a function that answers something odd is an invalid token" do
      conn =
        post(secured(authenticate: fn _ -> :surprise end), rpc("ping"), [
          {"authorization", "Bearer x"}
        ])

      assert conn.status == 401
    end

    test "is checked before the body is read" do
      conn = post(secured(), "{nope")
      assert conn.status == 401
    end
  end

  describe "who is asking" do
    defp as(token, tool_call) do
      opts = HTTP.init(server: WhoServer, authenticate: &__MODULE__.authenticate/1)
      post(opts, tool_call, [{"authorization", "Bearer #{token}"}])
    end

    @greet %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "greet", "arguments" => %{"name" => "Ann"}}
    }

    test "the context from the token is the third argument of the authorize function" do
      assert %{"result" => %{"isError" => false}} = "ann-token" |> as(@greet) |> json()

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               "bob-token" |> as(@greet) |> json()

      assert text =~ "Only Ann may greet."
    end

    test "a hook of two arguments still works over HTTP, and never sees the context" do
      opts = HTTP.init(server: TwoArgServer, authenticate: &__MODULE__.authenticate/1)
      headers = [{"authorization", "Bearer bob-token"}]

      assert %{"result" => %{"isError" => false}} = opts |> post(@greet, headers) |> json()

      refused = put_in(@greet, ["params", "arguments", "name"], "nobody")

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               opts |> post(refused, headers) |> json()

      assert text =~ "not on the list"
    end

    test "stdio, which has no context, passes an empty one" do
      assert {:reply, %{"result" => %{"isError" => true}}} = WhoServer.handle(@greet)

      assert {:reply, %{"result" => %{"isError" => false}}} =
               WhoServer.handle(@greet, %{user: "ann"})
    end
  end

  describe "authorize_request" do
    defp scoped(token, message) do
      opts =
        secured(authorize_request: &__MODULE__.require_scope/2)

      post(opts, message, [{"authorization", "Bearer #{token}"}])
    end

    test "answers 403 insufficient_scope, naming the scope, when the token lacks it" do
      call = rpc("tools/call", %{"name" => "greet", "arguments" => %{"name" => "Ann"}})

      conn = scoped("bob-token", call)
      assert conn.status == 403

      assert header(conn, "www-authenticate") ==
               ~s(Bearer error="insufficient_scope", scope="write", resource_metadata="#{@metadata}")

      assert scoped("ann-token", call).status == 200
    end

    test "does not touch what needs no scope" do
      assert scoped("bob-token", rpc("tools/list")).status == 200
    end

    test "an answer it was not told to expect is a plain 403" do
      opts = secured(authorize_request: fn _, _ -> :maybe end)
      conn = post(opts, rpc("ping"), [{"authorization", "Bearer ann-token"}])
      assert conn.status == 403
      assert get_resp_header(conn, "www-authenticate") == []
    end
  end
end
