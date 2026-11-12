defmodule DDD.MCP.HTTP do
  @moduledoc """
  The HTTP transport of an MCP server (the "Streamable HTTP" transport, in its simplest
  form), as a Plug. The server module (`DDD.MCP.Server`) does the work; this moves JSON in
  and out and says who is asking.

      # in a Phoenix or Plug router
      forward "/mcp", DDD.MCP.HTTP,
        server: MyApp.Interface.MCP,
        authenticate: &MyApp.MCPAuth.authenticate/1,
        resource_metadata: "https://shop.example.com/.well-known/oauth-protected-resource/mcp",
        allowed_origins: ["https://claude.ai"]

  ## What it does

    * `POST` takes one JSON-RPC message and answers `200` with the JSON reply, or `202` with
      no body for a notification or a client's response. It does not stream and keeps no
      session, so any node can answer any request.
    * Every other method gets `405`. A batch (a JSON array) is refused, as the protocol
      versions this server speaks do not use them.
    * A request whose `MCP-Protocol-Version` header names a version the server does not speak
      gets `400`.
    * An `Origin` header that is not in `:allowed_origins` gets `403`, so a web page cannot
      drive a server on `localhost` (DNS rebinding). Requests without an `Origin` (command
      line clients, other servers) are not affected.

  ## Authentication

  The OAuth parts of MCP (see the specification's "Authorization") belong to the application:
  it knows its users and issues or accepts tokens. This transport only asks. `:authenticate`
  is a function of the bearer token that answers

    * `{:ok, context}`: a map saying who it is. It is the third argument of the server's
      `authorize:` function (a function of three arguments; one of two never sees it).
    * `{:error, :invalid_token}`: unknown, expired or for another audience.

  A request without a token, or with an invalid one, gets `401` and a `WWW-Authenticate:
  Bearer` header carrying `resource_metadata` (the URL of the server's RFC 9728 document, a
  string or a function of no arguments), which is how a client finds out where to log in.

  `:authorize_request` is optional: a function of the decoded message and the context that
  answers `:ok` or `{:error, {:insufficient_scope, "scope names"}}`. The error becomes `403`
  with `WWW-Authenticate: Bearer error="insufficient_scope", scope="..."`, which tells the
  client to ask the user for more. Use it for what depends on the token and not on the user,
  such as the scope a tool needs.

  `:authenticate` is required. Pass `authenticate: :none` to serve without authentication,
  which is for local development only.

  CORS is not handled here: a browser client needs the application to answer `OPTIONS`.
  """

  alias Plug.Conn

  # Plug is optional: an application that does not serve MCP over HTTP need not have it.
  @compile {:no_warn_undefined, [Plug.Conn]}

  @max_body 1_000_000

  def init(opts) do
    authenticate =
      case Keyword.fetch(opts, :authenticate) do
        {:ok, fun} when is_function(fun, 1) ->
          fun

        {:ok, :none} ->
          :none

        _ ->
          raise ArgumentError,
                "DDD.MCP.HTTP needs `authenticate:` (a function of the bearer token, or " <>
                  ":none to serve without authentication)"
      end

    %{
      server: Keyword.fetch!(opts, :server),
      authenticate: authenticate,
      authorize_request: Keyword.get(opts, :authorize_request),
      resource_metadata: Keyword.get(opts, :resource_metadata),
      allowed_origins: Keyword.get(opts, :allowed_origins, [])
    }
  end

  def call(conn, opts) do
    conn = Conn.put_resp_header(conn, "cache-control", "no-store")

    with :ok <- check_method(conn),
         :ok <- check_origin(conn, opts),
         :ok <- check_protocol_version(conn),
         {:ok, context} <- authenticate(conn, opts),
         {:ok, message, conn} <- read_message(conn),
         :ok <- check_request(message, context, opts) do
      respond(conn, opts.server, message, context)
    else
      {:error, status, headers, body} -> send_json(conn, status, body, headers)
    end
  end

  # ── Checks ──────────────────────────────────────────────────────────────

  defp check_method(%{method: "POST"}), do: :ok

  defp check_method(_conn),
    do: {:error, 405, [{"allow", "POST"}], rpc_error(-32_600, "Use POST")}

  defp check_origin(conn, opts) do
    case Conn.get_req_header(conn, "origin") do
      [] -> :ok
      [origin] -> if origin in opts.allowed_origins, do: :ok, else: forbidden_origin()
      _many -> forbidden_origin()
    end
  end

  defp forbidden_origin, do: {:error, 403, [], rpc_error(-32_600, "Origin not allowed")}

  defp check_protocol_version(conn) do
    case Conn.get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version] ->
        if version in DDD.MCP.protocol_versions(),
          do: :ok,
          else: {:error, 400, [], rpc_error(-32_600, "Unsupported protocol version")}

      _many ->
        {:error, 400, [], rpc_error(-32_600, "Unsupported protocol version")}
    end
  end

  defp authenticate(_conn, %{authenticate: :none}), do: {:ok, %{}}

  defp authenticate(conn, %{authenticate: fun} = opts) do
    case bearer_token(conn) do
      nil ->
        {:error, 401, [challenge(opts, [])], rpc_error(-32_001, "Authentication required")}

      token ->
        case fun.(token) do
          {:ok, context} when is_map(context) ->
            {:ok, context}

          _ ->
            {:error, 401, [challenge(opts, error: "invalid_token")],
             rpc_error(-32_001, "Invalid token")}
        end
    end
  end

  defp check_request(_message, _context, %{authorize_request: nil}), do: :ok

  defp check_request(message, context, %{authorize_request: fun} = opts) do
    case fun.(message, context) do
      :ok ->
        :ok

      {:error, {:insufficient_scope, scope}} when is_binary(scope) ->
        {:error, 403, [challenge(opts, error: "insufficient_scope", scope: scope)],
         rpc_error(-32_001, "Insufficient scope: #{scope}")}

      _ ->
        {:error, 403, [], rpc_error(-32_001, "Not allowed")}
    end
  end

  defp bearer_token(conn) do
    with [header] <- Conn.get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token = String.trim(token),
         true <- token != "" do
      token
    else
      _ -> nil
    end
  end

  # `WWW-Authenticate: Bearer error="...", scope="...", resource_metadata="..."`
  defp challenge(opts, params) do
    params =
      case resource_metadata(opts) do
        nil -> params
        url -> params ++ [resource_metadata: url]
      end

    value =
      case params do
        [] ->
          "Bearer"

        params ->
          "Bearer " <>
            Enum.map_join(params, ", ", fn {k, v} -> ~s(#{k}="#{header_value(v)}") end)
      end

    {"www-authenticate", value}
  end

  defp resource_metadata(%{resource_metadata: fun}) when is_function(fun, 0), do: fun.()
  defp resource_metadata(%{resource_metadata: url}), do: url

  # A value inside a quoted string can not hold a quote or a line break.
  defp header_value(value), do: value |> to_string() |> String.replace(~r/["\\\r\n]/, "")

  # ── The message ─────────────────────────────────────────────────────────

  # The body may have been parsed by `Plug.Parsers` in front of this plug, or not.
  defp read_message(%{body_params: %{__struct__: Plug.Conn.Unfetched}} = conn) do
    case Conn.read_body(conn, length: @max_body) do
      {:ok, body, conn} -> decode(body, conn)
      {:more, _partial, _conn} -> {:error, 413, [], rpc_error(-32_600, "Request too large")}
      {:error, _reason} -> {:error, 400, [], rpc_error(-32_700, "Could not read the request")}
    end
  end

  defp read_message(%{body_params: %{"_json" => _}}),
    do: {:error, 400, [], rpc_error(-32_600, "Batches are not supported")}

  defp read_message(%{body_params: params} = conn) when map_size(params) > 0,
    do: {:ok, params, conn}

  defp read_message(_conn), do: {:error, 400, [], rpc_error(-32_600, "Empty request")}

  defp decode(body, conn) do
    case Jason.decode(body) do
      {:ok, %{} = message} -> {:ok, message, conn}
      {:ok, _array_or_scalar} -> {:error, 400, [], rpc_error(-32_600, "Invalid Request")}
      {:error, _} -> {:error, 400, [], DDD.MCP.parse_error()}
    end
  end

  defp respond(conn, server, message, context) do
    if client_response?(message) do
      Conn.send_resp(conn, 202, "")
    else
      case server.handle(message, context) do
        {:reply, reply} -> send_json(conn, 200, reply, [])
        :noreply -> Conn.send_resp(conn, 202, "")
      end
    end
  end

  # What a client sends back to a request of the server: a `result` or an `error`, no method.
  defp client_response?(message),
    do:
      not Map.has_key?(message, "method") and
        (is_map_key(message, "result") or is_map_key(message, "error"))

  defp rpc_error(code, message),
    do: %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => code, "message" => message}}

  defp send_json(conn, status, body, headers) do
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> Conn.put_resp_header(conn, k, v) end)

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end
end
