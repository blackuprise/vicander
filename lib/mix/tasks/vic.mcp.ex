defmodule Mix.Tasks.Vic.Mcp do
  @shortdoc "Serves the application over MCP on stdin and stdout"
  @moduledoc """
  Serves a `DDD.MCP.Server` module as a Model Context Protocol server on standard input and
  output, for an AI client to launch:

      mix vic.mcp TodoApp.Interface.MCP
      mix vic.mcp TodoApp.Interface.MCP --read-only

      claude mcp add todo -- mix vic.mcp TodoApp.Interface.MCP

  Standard output carries only protocol messages, so the task sends the logger to standard
  error (before the application starts, so the outbox poller can run when configured), turns
  the Ecto SQL log off, and silences Mix's own output.

    * `--read-only` refuses every command tool (queries and resources only)
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, names} = OptionParser.parse!(args, strict: [read_only: :boolean])

    server =
      case names do
        [name] -> Module.concat([name])
        _ -> Mix.raise("usage: mix vic.mcp ServerModule [--read-only]")
      end

    # Before the app starts: nothing may write to standard output but the protocol.
    Mix.shell(Mix.Shell.Quiet)
    route_logger(:standard_error)

    # Compile and load the application (without starting it) to find its repo.
    Mix.Task.run("app.config")

    # The SQL log of the application's repo goes off too (the repo's config lives in its app).
    repo = DDD.Config.repo!()
    app = repo.config()[:otp_app]
    repo_config = Application.get_env(app, repo, [])
    Application.put_env(app, repo, Keyword.put(repo_config, :log, false))

    Mix.Task.run("app.start")
    route_logger(:standard_error)

    unless Code.ensure_loaded?(server) and function_exported?(server, :serve, 1) do
      Mix.raise("#{inspect(server)} is not a DDD.MCP.Server module")
    end

    server.serve(Keyword.take(opts, [:read_only]))
  end

  @doc false
  # The console handler's output device can't be changed once it runs, so it is replaced by
  # an identical one writing to `device` (`:standard_error` or `:standard_io`).
  def route_logger(device) do
    {:ok, config} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)

    handler =
      config |> Map.drop([:id, :module]) |> put_in([:config, :type], device)

    :ok = :logger.add_handler(:default, :logger_std_h, handler)
  end
end
