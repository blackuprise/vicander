defmodule DDD.MCP do
  @moduledoc """
  The application as a [Model Context Protocol](https://modelcontextprotocol.io) server: an AI
  client can call its commands and queries as tools and read its aggregates as resources.

  This module is the protocol core. It takes one decoded JSON-RPC message and returns the reply,
  so a transport (`DDD.MCP.Stdio`, or an HTTP Plug later) only moves JSON. Use it through a
  server module (`DDD.MCP.Server`).

  ## What is exposed

    * **Tools.** Each listed command and query is a tool. Its input schema is built from the
      command's fields (`DDD.MCP.Schema`), its description from `description "..."`. Queries are
      marked `readOnlyHint: true`.
    * **Resources.** Each listed aggregate is read-only: `name://<identity>` reads one, and
      `name://by/<field>/<value>` runs a `find_by` the repository port declares (at most 100
      results). `resources/list` is empty on purpose: a client is never handed a whole table.

  ## What a client is told about failures

  A **business** error (validation, not found, a precondition) is returned with its code,
  message and violations, so the client can correct itself. An **infrastructure** error is a
  generic "the operation failed" and the details only go to the log. A malformed request gets a
  JSON-RPC error saying what was wrong.

  A read-only server refuses every command tool. An `:authorize` function is called before
  every tool call and resource read and may refuse it.
  """

  require Logger

  alias DDD.Error
  alias DDD.MCP.{Args, Json, Registry}

  @versions ["2025-06-18", "2025-03-26", "2024-11-05"]
  @lookup_limit 100

  # JSON-RPC error codes
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603
  @not_found -32_002
  @denied -32_001

  @doc """
  Handle one decoded JSON-RPC message: `{:reply, response}` or `:noreply` (notifications).

  `context` says who is asking. A transport that authenticates its callers (`DDD.MCP.HTTP`)
  passes what it learned there, and the server's `authorize:` function receives it as a third
  argument; with stdio, where one process is one client, it is `%{}`.
  """
  @spec handle(Registry.t(), term(), map()) :: {:reply, map()} | :noreply
  def handle(registry, message, context \\ %{})

  def handle(
        %Registry{} = registry,
        %{"jsonrpc" => "2.0", "method" => method} = message,
        context
      )
      when is_binary(method) do
    case Map.fetch(message, "id") do
      :error -> :noreply
      {:ok, id} -> {:reply, respond(registry, id, method, message["params"] || %{}, context)}
    end
  end

  def handle(_registry, %{"id" => id}, _context),
    do: {:reply, error(id, @invalid_request, "Invalid Request")}

  def handle(_registry, _other, _context),
    do: {:reply, error(nil, @invalid_request, "Invalid Request")}

  @doc "The protocol versions this server speaks, newest first."
  @spec protocol_versions() :: [String.t()]
  def protocol_versions, do: @versions

  @doc "A parse-error response, for a transport that received text that is not JSON."
  def parse_error, do: error(nil, -32_700, "Parse error")

  defp respond(registry, id, method, params, context) do
    case dispatch(registry, method, params, context) do
      {:ok, result} -> %{"jsonrpc" => "2.0", "id" => id, "result" => result}
      {:error, code, message} -> error(id, code, message)
    end
  rescue
    exception ->
      Logger.error(
        "[mcp] #{method} crashed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      error(id, @internal_error, "Internal error")
  end

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  # ── Methods ───────────────────────────────────────────────────────────────

  defp dispatch(registry, "initialize", params, _context),
    do: {:ok, initialize(registry, params)}

  defp dispatch(_registry, "ping", _params, _context), do: {:ok, %{}}

  defp dispatch(registry, "tools/list", _params, _context),
    do: {:ok, %{"tools" => list_tools(registry)}}

  defp dispatch(registry, "tools/call", params, context), do: call_tool(registry, params, context)
  defp dispatch(_registry, "resources/list", _params, _context), do: {:ok, %{"resources" => []}}

  defp dispatch(registry, "resources/templates/list", _params, _context),
    do: {:ok, %{"resourceTemplates" => list_templates(registry)}}

  defp dispatch(registry, "resources/read", params, context),
    do: read_resource(registry, params, context)

  defp dispatch(_registry, method, _params, _context),
    do: {:error, @method_not_found, "Method not found: #{method}"}

  defp initialize(registry, params) do
    version =
      if params["protocolVersion"] in @versions,
        do: params["protocolVersion"],
        else: hd(@versions)

    capabilities =
      %{}
      |> put_if(visible_tools(registry) != [], "tools", %{"listChanged" => false})
      |> put_if(
        map_size(registry.repos) > 0,
        "resources",
        %{"subscribe" => false, "listChanged" => false}
      )

    %{
      "protocolVersion" => version,
      "capabilities" => capabilities,
      "serverInfo" => %{"name" => registry.name, "version" => registry.version}
    }
    |> put_if(registry.instructions != nil, "instructions", registry.instructions)
  end

  # ── Tools ─────────────────────────────────────────────────────────────────

  defp visible_tools(%Registry{read_only: true, tools: tools}),
    do: tools |> Map.values() |> Enum.filter(&(&1.kind == :query))

  defp visible_tools(%Registry{tools: tools}), do: Map.values(tools)

  defp list_tools(registry) do
    registry
    |> visible_tools()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "inputSchema" => tool.input_schema,
        "annotations" => %{"readOnlyHint" => tool.kind == :query}
      }
    end)
  end

  defp call_tool(registry, %{"name" => name} = params, context) when is_binary(name) do
    arguments = params["arguments"] || %{}

    with {:ok, tool} <- fetch_tool(registry, name),
         :ok <- check_arguments(tool, arguments) do
      {:ok, run_tool(registry, tool, arguments, context)}
    end
  end

  defp call_tool(_registry, _params, _context),
    do: {:error, @invalid_params, "tools/call needs a tool \"name\""}

  defp fetch_tool(registry, name) do
    case Map.fetch(registry.tools, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, @invalid_params, "Unknown tool: #{name}"}
    end
  end

  defp check_arguments(_tool, arguments) when not is_map(arguments),
    do: {:error, @invalid_params, "\"arguments\" must be an object"}

  defp check_arguments(tool, arguments) do
    case Map.keys(arguments) -- tool.params do
      [] ->
        :ok

      unknown ->
        {:error, @invalid_params,
         "Unknown argument(s) for #{tool.name}: #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  defp run_tool(%Registry{read_only: true}, %{kind: :command, name: name}, _arguments, _context) do
    tool_error(
      Error.business(
        code: :read_only,
        message: "This server is read-only: #{name} changes data and is not available."
      )
    )
  end

  defp run_tool(registry, tool, arguments, context) do
    case authorize(registry, tool.name, arguments, context) do
      :ok -> execute(tool, arguments)
      {:error, error} -> tool_error(error)
    end
  end

  defp execute(tool, arguments) do
    case Args.cast(tool.module, arguments) do
      {:error, error} ->
        tool_error(error)

      {:ok, attrs} ->
        result =
          try do
            tool.module.call(attrs)
          rescue
            exception ->
              Logger.error("[mcp] #{tool.name} crashed: " <> Exception.message(exception))
              {:error, Error.wrap(exception, %{tool: tool.name})}
          end

        Logger.info("[mcp] tool #{tool.name} #{outcome(result)}")
        present(result)
    end
  end

  defp outcome({:ok, _}), do: "ok"

  defp outcome({:error, %Error{} = error}),
    do: "failed (#{error.kind}: #{Enum.join(Error.codes(error), ", ")})"

  defp outcome({:error, _}), do: "failed"

  defp present({:ok, value}), do: %{"content" => [text(Json.encode(value))], "isError" => false}
  defp present({:error, %Error{} = error}), do: tool_error(error)
  defp present({:error, reason}), do: tool_error(Error.wrap(reason, %{}))

  # Business errors tell the client what to fix. Anything else is not the client's business.
  defp tool_error(%Error{kind: :business} = error) do
    %{"content" => [text(Json.encode(%{"error" => error_body(error)}))], "isError" => true}
  end

  defp tool_error(%Error{} = error) do
    Logger.error("[mcp] infrastructure error: #{inspect(error)}")

    %{
      "content" => [text("The operation failed. Try again later.")],
      "isError" => true
    }
  end

  defp error_body(error) do
    %{"code" => error.code, "message" => error.message}
    |> put_if(error.entity != nil, "entity", error.entity && entity_name(error.entity))
    |> put_if(error.entity_id != nil, "entity_id", error.entity_id)
    |> put_if(error.violations != [], "violations", Enum.map(error.violations, &violation/1))
    |> put_if(error.details != %{}, "details", error.details)
  end

  # "TodoApp.Domain.TodoList" is reported as "TodoList": what the client needs to tell which
  # kind of thing it was, without the application's module layout.
  defp entity_name(module), do: module |> Module.split() |> List.last()

  defp violation(violation) do
    %{"field" => violation.field, "code" => violation.code, "message" => violation.message}
    |> put_if(violation.details != %{}, "details", violation.details)
  end

  defp text(string), do: %{"type" => "text", "text" => string}

  # ── Authorization ─────────────────────────────────────────────────────────

  defp authorize(%Registry{authorize: nil}, _name, _arguments, _context), do: :ok

  defp authorize(%Registry{authorize: fun}, name, arguments, context) do
    case run_hook(fun, name, arguments, context) do
      :ok ->
        :ok

      {:error, %Error{kind: :business} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.business(code: :not_authorized, message: refusal(reason))}

      _other ->
        {:error, Error.business(code: :not_authorized, message: "Not allowed.")}
    end
  end

  # A hook of two arguments (`name, arguments`) is as before; one of three also gets the context.
  defp run_hook(fun, name, arguments, context) when is_function(fun, 3),
    do: fun.(name, arguments, context)

  defp run_hook(fun, name, arguments, _context), do: fun.(name, arguments)

  defp refusal(reason) when is_binary(reason), do: reason
  defp refusal(_reason), do: "Not allowed."

  # ── Resources ─────────────────────────────────────────────────────────────

  defp list_templates(registry) do
    registry.repos
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.flat_map(fn entity ->
      [
        template(entity.name, "#{entity.name}://{id}", entity.description)
        | for fields <- entity.lookups do
            template(
              "#{entity.name}_by_#{Enum.join(fields, "_and_")}",
              "#{entity.name}://by/" <> Enum.map_join(fields, "/", &"#{&1}/{#{&1}}"),
              "#{entity.description} (lookup by #{Enum.join(fields, " and ")}, " <>
                "at most #{@lookup_limit} results)"
            )
          end
      ]
    end)
  end

  defp template(name, uri_template, description) do
    %{
      "uriTemplate" => uri_template,
      "name" => name,
      "description" => description,
      "mimeType" => "application/json"
    }
  end

  defp read_resource(registry, %{"uri" => uri}, context) when is_binary(uri) do
    with {:ok, entity, rest} <- locate(registry, uri),
         :ok <- authorize_read(registry, entity, uri, context),
         {:ok, value} <- read(entity, rest, uri) do
      {:ok,
       %{
         "contents" => [
           %{"uri" => uri, "mimeType" => "application/json", "text" => Json.encode(value)}
         ]
       }}
    end
  end

  defp read_resource(_registry, _params, _context),
    do: {:error, @invalid_params, "resources/read needs a \"uri\""}

  defp locate(registry, uri) do
    with [scheme, rest] <- String.split(uri, "://", parts: 2),
         {:ok, entity} <- Map.fetch(registry.repos, scheme) do
      {:ok, entity, rest}
    else
      _ -> {:error, @not_found, "Resource not found: #{uri}"}
    end
  end

  defp authorize_read(registry, entity, uri, context) do
    case authorize(registry, "resource:" <> entity.name, %{"uri" => uri}, context) do
      :ok -> :ok
      {:error, error} -> {:error, @denied, error.message}
    end
  end

  defp read(entity, rest, uri) do
    do_read(entity, rest, uri)
  rescue
    exception -> failed_read(entity, uri, Exception.message(exception))
  end

  defp do_read(entity, "by/" <> lookup, uri), do: lookup(entity, lookup, uri)

  defp do_read(entity, id, uri) do
    impl = entity.port.impl()

    case read_only(impl, fn -> impl.find_by_id(URI.decode(id)) end) do
      {:ok, aggregate} -> {:ok, aggregate}
      {:error, :not_found} -> {:error, @not_found, "Resource not found: #{uri}"}
      other -> failed_read(entity, uri, other)
    end
  end

  defp lookup(entity, path, uri) do
    segments = String.split(path, "/")

    with true <- rem(length(segments), 2) == 0,
         {names, values} = pairs(segments),
         {:ok, fields} <- find_lookup(entity, names),
         {:ok, args} <- cast_lookup(entity, fields, values) do
      run_lookup(entity, fields, args, uri)
    else
      _ -> {:error, @not_found, "Resource not found: #{uri}"}
    end
  end

  # ["a", 1, "b", 2] -> {["a", "b"], [1, 2]}
  defp pairs(segments) do
    segments |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1) |> Enum.unzip()
  end

  defp find_lookup(entity, names) do
    case Enum.find(entity.lookups, &(Enum.map(&1, fn f -> Atom.to_string(f) end) == names)) do
      nil -> :error
      fields -> {:ok, fields}
    end
  end

  defp cast_lookup(entity, fields, values) do
    types = Map.new(entity.aggregate.__ddd_fields__(), fn {name, type, _} -> {name, type} end)

    fields
    |> Enum.zip(values)
    |> Enum.reduce_while({:ok, []}, fn {field, value}, {:ok, acc} ->
      case Args.from_string(Map.fetch!(types, field), URI.decode(value)) do
        {:ok, cast} -> {:cont, {:ok, [cast | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, args} -> {:ok, Enum.reverse(args)}
      :error -> :error
    end
  end

  defp run_lookup(entity, fields, args, uri) do
    impl = entity.port.impl()
    function = :"find_by_#{Enum.join(fields, "_and_")}"

    case read_only(impl, fn -> apply(impl, function, args) end) do
      list when is_list(list) ->
        {items, rest} = Enum.split(list, @lookup_limit)

        {:ok,
         %{
           "items" => items,
           "count" => length(items),
           "limit" => @lookup_limit,
           "truncated" => rest != []
         }}

      other ->
        failed_read(entity, uri, other)
    end
  end

  defp failed_read(entity, uri, reason) do
    Logger.error("[mcp] reading #{uri} (#{entity.name}) failed: #{inspect(reason)}")
    {:error, @internal_error, "The resource could not be read."}
  end

  # The adapter's repo (when it has one) reads inside a read-only transaction.
  defp read_only(impl, fun) do
    if function_exported?(impl, :repo, 0),
      do: DDD.Query.read_only(impl.repo(), fun),
      else: fun.()
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map
end
