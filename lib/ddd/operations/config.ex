defmodule DDD.Config do
  @moduledoc """
  The framework's application configuration, in one place.

      # config/config.exs of your application
      config :vicander, repo: MyApp.Repo

  `repo` is the `Ecto.Repo` the framework uses unless a command, query, handler or projection
  names another with `repo:` (for example `use DDD.Command, repo: MyApp.OtherRepo`). It is read
  when the code runs, not when it compiles, so a test can change it.

  The other keys are documented where they apply:

    * `config :vicander, :outbox, ...` - retries and backoff of the outbox (`DDD.Outbox.Poller`)
    * `config :vicander, :dead_letters, ...` - what to do with events that gave up
      (`DDD.Outbox.DeadLetterPolicy`)
    * `config :vicander, :health, ...` - thresholds and projections (`DDD.Health`)
  """

  @doc "The configured repo. Raises, saying how to configure it, when there is none."
  @spec repo!() :: module()
  def repo! do
    case Application.get_env(:vicander, :repo) do
      repo when is_atom(repo) and not is_nil(repo) ->
        repo

      _missing ->
        raise ArgumentError, """
        the framework does not know which Ecto repo to use.

        Configure it once, for example in config/config.exs:

            config :vicander, repo: MyApp.Repo

        or name the repo where it is used: `use DDD.Command, repo: MyApp.Repo`.
        """
    end
  end

  @doc """
  Resolve a `repo:` option: `:default` is the configured repo, `nil` stays `nil` (no
  transaction), and a module is itself.
  """
  @spec repo(:default | nil | module()) :: module() | nil
  def repo(:default), do: repo!()
  def repo(nil), do: nil
  def repo(repo) when is_atom(repo), do: repo
end
