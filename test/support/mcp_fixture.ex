defmodule DDD.Test.Greet do
  @moduledoc false
  use DDD.Command, transaction: false

  command do
    description "Greet someone"
    field :name, :string, required: true, description: "Who to greet"
  end

  @impl DDD.Command
  def execute(%__MODULE__{name: name}), do: {:ok, %{greeting: "Hello, #{name}!"}}
end

defmodule DDD.Test.Lookup do
  @moduledoc false
  use DDD.Query, transaction: false

  query do
    description "Look a word up"
    field :word, :string, required: true, description: "The word"
  end

  @impl DDD.Query
  def execute(%__MODULE__{word: word}), do: {:ok, %{word: word, length: String.length(word)}}
end

defmodule DDD.Test.MCPServer do
  @moduledoc """
  A small MCP server for the tests of `mix vic.mcp`, which takes a server module by name.
  """
  use DDD.MCP.Server, commands: [DDD.Test.Greet], queries: [DDD.Test.Lookup]
end
