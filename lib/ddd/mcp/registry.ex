defmodule DDD.MCP.Registry do
  @moduledoc """
  What an MCP server exposes, checked once when the server is built.

  `build!/2` turns the options of `use DDD.MCP.Server` into tools (commands and queries) and
  resources (aggregates). It raises `ArgumentError` for anything that would reach a client
  broken: an exposed module without a description, two tools with the same name, an entity with
  no repository.
  """

  alias DDD.MCP.Schema

  defstruct name: "vicander",
            version: "0.0.0",
            instructions: nil,
            read_only: false,
            authorize: nil,
            tools: %{},
            repos: %{}

  @type tool :: %{
          name: String.t(),
          module: module(),
          kind: :command | :query,
          description: String.t(),
          input_schema: map(),
          params: [String.t()]
        }

  @type entity :: %{
          name: String.t(),
          aggregate: module(),
          port: module(),
          description: String.t(),
          lookups: [[atom()]]
        }

  @type t :: %__MODULE__{}

  @spec build!(module(), keyword()) :: t()
  def build!(server, opts) do
    commands = for entry <- Keyword.get(opts, :commands, []), do: tool!(entry, :command)
    queries = for entry <- Keyword.get(opts, :queries, []), do: tool!(entry, :query)
    repos = for entry <- Keyword.get(opts, :repos, []), do: repo!(entry)

    %__MODULE__{
      name: Keyword.get_lazy(opts, :name, fn -> default_name(server) end),
      version: Keyword.get_lazy(opts, :version, fn -> app_version(server) end),
      instructions: Keyword.get(opts, :instructions),
      read_only: Keyword.get(opts, :read_only, false),
      authorize: authorize!(Keyword.get(opts, :authorize)),
      tools: unique!(commands ++ queries, "tool"),
      repos: unique!(repos, "resource")
    }
  end

  # A hook that can not be called is found when the server is built, not on a client's first call.
  defp authorize!(nil), do: nil
  defp authorize!(fun) when is_function(fun, 2) or is_function(fun, 3), do: fun

  defp authorize!(other) do
    raise ArgumentError,
          "`authorize:` must be a function of two arguments (tool, arguments) or three " <>
            "(tool, arguments, context), got: #{inspect(other)}"
  end

  # ── Tools ─────────────────────────────────────────────────────────────────

  defp tool!(entry, kind) do
    {module, opts} = split(entry)
    Code.ensure_loaded!(module)
    fun = if kind == :command, do: :__cmd_repo__, else: :__query_repo__

    unless function_exported?(module, :__params__, 0) and function_exported?(module, fun, 0) do
      raise ArgumentError, "#{inspect(module)} is not a #{kind}, so it can't be exposed as one"
    end

    %{
      name: Keyword.get_lazy(opts, :name, fn -> snake_name(module) end),
      module: module,
      kind: kind,
      description: described!(module, module.__description__()),
      input_schema: Schema.input(module),
      params: Enum.map(module.__params__(), fn {name, _type, _opts} -> Atom.to_string(name) end)
    }
  end

  # ── Entities ──────────────────────────────────────────────────────────────

  # An entity is exposed through its repository port (`repo Aggregate do ... end`), which says
  # which aggregate it is and which lookups exist. Either the port or `{Aggregate,
  # repository: Port}` can be listed.
  defp repo!(entry) do
    {module, opts} = split(entry)
    Code.ensure_loaded!(module)

    {aggregate, port} =
      cond do
        function_exported?(module, :__repo_aggregate__, 0) ->
          {module.__repo_aggregate__(), module}

        function_exported?(module, :__ddd_kind__, 0) ->
          {module, Keyword.get(opts, :repository) || missing_repository!(module)}

        true ->
          raise ArgumentError,
                "#{inspect(module)} is neither an aggregate nor a repository port, " <>
                  "so it can't be listed in repos:"
      end

    Code.ensure_loaded!(aggregate)
    Code.ensure_loaded!(port)

    unless function_exported?(port, :impl, 0) do
      raise ArgumentError,
            "#{inspect(port)} must define impl/0 (the adapter in use) to be exposed over MCP. " <>
              "It is not generated: add `def impl, do: MyApp.YourAdapter` to the port " <>
              "(see \"Naming the adapter: impl/0\" in the README)"
    end

    %{
      name: Keyword.get_lazy(opts, :name, fn -> snake_name(aggregate) end),
      aggregate: aggregate,
      port: port,
      description: described!(aggregate, aggregate.__ddd_description__()),
      lookups: port.__repo_find_bys__()
    }
  end

  defp missing_repository!(module) do
    raise ArgumentError,
          "#{inspect(module)} needs a repository to be exposed: " <>
            "list `{#{inspect(module)}, repository: Port}` or the port itself"
  end

  # ── Shared ────────────────────────────────────────────────────────────────

  defp split({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp split(module) when is_atom(module), do: {module, []}

  defp described!(module, description) when description in [nil, ""] do
    raise ArgumentError,
          "#{inspect(module)} is exposed over MCP but has no description: add " <>
            "`description \"...\"` to it"
  end

  defp described!(_module, description), do: description

  defp unique!(items, label) do
    items
    |> Enum.group_by(& &1.name)
    |> Map.new(fn
      {name, [item]} ->
        {name, item}

      {name, items} ->
        modules = Enum.map_join(items, " and ", &inspect(module_of(&1)))

        raise ArgumentError,
              "two #{label}s are named #{inspect(name)}: #{modules}. " <>
                "Give one a name: `{Module, name: \"other_name\"}`"
    end)
  end

  defp module_of(%{module: module}), do: module
  defp module_of(%{aggregate: aggregate}), do: aggregate

  defp snake_name(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp default_name(server) do
    case Application.get_application(server) do
      nil -> "ddd"
      app -> Atom.to_string(app)
    end
  end

  # The version of the application the server module belongs to.
  defp app_version(server) do
    with app when not is_nil(app) <- Application.get_application(server),
         vsn when not is_nil(vsn) <- Application.spec(app, :vsn) do
      List.to_string(vsn)
    else
      _ -> "0.0.0"
    end
  end
end
