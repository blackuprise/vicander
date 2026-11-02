defmodule DDD.MCP.Stdio do
  @moduledoc """
  The stdio transport: one JSON-RPC message per line on standard input, one reply per line on
  standard output. Standard output carries only protocol messages, so anything that logs must
  write to standard error (`mix vic.mcp` arranges that).
  """

  require Logger

  @doc """
  Read messages until the input ends, writing each reply as one line.

  Options: `:read_only` (overrides the server's setting), `:input` and `:output` (IO devices,
  default `:stdio`).
  """
  @spec serve(DDD.MCP.Registry.t(), keyword()) :: :ok
  def serve(registry, opts \\ []) do
    registry =
      case Keyword.fetch(opts, :read_only) do
        {:ok, read_only} -> %{registry | read_only: read_only}
        :error -> registry
      end

    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stdio)
    loop(registry, input, output)
  end

  defp loop(registry, input, output) do
    case IO.read(input, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        Logger.error("[mcp] reading input failed: #{inspect(reason)}")
        :ok

      line ->
        line |> String.trim() |> process(registry, output)
        loop(registry, input, output)
    end
  end

  defp process("", _registry, _output), do: :ok

  defp process(line, registry, output) do
    reply =
      case Jason.decode(line) do
        {:ok, message} -> DDD.MCP.handle(registry, message)
        {:error, _} -> {:reply, DDD.MCP.parse_error()}
      end

    case reply do
      {:reply, response} -> IO.write(output, Jason.encode!(response) <> "\n")
      :noreply -> :ok
    end
  end
end
