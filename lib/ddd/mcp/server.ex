defmodule DDD.MCP.Server do
  @moduledoc """
  Declares which commands, queries and aggregates an application offers over MCP.

      defmodule MyApp.Interface.MCP do
        use DDD.MCP.Server,
          instructions: "Manage todo lists.",
          commands: [MyApp.Commands.CreateList, {MyApp.Commands.RenameItem, name: "rename_todo"}],
          queries: [MyApp.Queries.OpenItems],
          repos: [MyApp.TodoList.Repository],
          read_only: false,
          authorize: &MyApp.MCPPolicy.authorize/2
      end

  Nothing is exposed unless it is listed here, and the commands and entities themselves know
  nothing about MCP. The level of access is what you list: a server with only `queries:` and
  `repos:` can only read.

    * `commands:` and `queries:` become tools. A module is listed alone, or as
      `{Module, name: "tool_name"}`. The default name is the last module segment in snake case.
    * `repos:` become read-only resources, one per repository. List the repository port (it says which aggregate
      and which `find_by` lookups exist), or `{Aggregate, repository: Port}`. The port must
      define `impl/0`, which you write (see "Naming the adapter: impl/0" in the README).
    * `read_only: true` refuses every command tool.
    * `authorize:` is a function `(name, arguments) -> :ok | {:error, reason}` called before
      each tool call (with the tool's name) and resource read (with `"resource:<name>"` and
      `%{"uri" => uri}`).
    * `name:`, `version:` and `instructions:` are reported to the client.

  Every exposed module needs a `description`. A missing one, or two tools with the same name,
  raises when the server is built (at startup), not when a client calls.

  The module gets `handle/1` (one decoded JSON-RPC message), `serve/1` (the stdio loop) and
  `registry/0`. Run it with `mix vic.mcp MyApp.Interface.MCP`.
  """

  defmacro __using__(opts) do
    quote do
      @doc false
      def __mcp_opts__, do: unquote(opts)

      @doc "The checked description of what this server exposes (built once, then cached)."
      def registry do
        key = {DDD.MCP.Server, __MODULE__}

        case :persistent_term.get(key, nil) do
          nil ->
            registry = DDD.MCP.Registry.build!(__MODULE__, __mcp_opts__())
            :persistent_term.put(key, registry)
            registry

          registry ->
            registry
        end
      end

      @doc """
      Handle one decoded JSON-RPC message: `{:reply, response}` or `:noreply`. `context` says who
      is asking (see `DDD.MCP.HTTP`); it is the third argument of an `authorize:` function that
      takes three.
      """
      def handle(message, context \\ %{}), do: DDD.MCP.handle(registry(), message, context)

      @doc """
      Serve MCP on standard input and output until the input ends. Options: `:read_only`
      (overrides the server's setting), `:input` and `:output` (IO devices).
      """
      def serve(opts \\ []), do: DDD.MCP.Stdio.serve(registry(), opts)
    end
  end
end
