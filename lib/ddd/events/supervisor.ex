defmodule DDD.Supervisor do
  @moduledoc """
  Starts what the framework needs at runtime, in the right order: the event bus, the handler
  subscriptions, the outbox poller and the dead-letter handler. Put it in your supervision tree
  after your repo:

      children = [
        MyApp.Repo,
        {DDD.Supervisor, handlers: [MyApp.Handlers.SendWelcome, MyApp.Projections.ListSummary]}
      ]

  The repo is `config :vicander, repo: MyApp.Repo` (see `DDD.Config`).

  ## Options

    * `:handlers` - the event handlers and projections (modules that `use DDD.EventHandler` or
      `DDD.Projection`) to subscribe. They are subscribed before the poller starts, because an
      event with no subscribed handler counts as delivered. Default: none.
    * `:poller` - options for `DDD.Outbox.Poller` (`:interval_ms`, `:batch_size`, ...), or
      `false` for no poller and no dead-letter handler: what a test or a web-only node wants.
      Default: `[]`, which polls every 500 ms in batches of 100.
    * `:retention` - `[older_than_days: 30]` (and optionally `:every_ms`) to prune published
      events from the outbox on a timer (`DDD.Outbox.Retention`). Default: never prune.
    * `:repo` - another repo than the configured one
    * `:name` - the supervisor's name (default `DDD.Supervisor`)

  If the event bus restarts, it forgets its subscriptions, so the supervisor restarts everything
  after it (the subscriptions and the poller) too.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    repo = Keyword.get_lazy(opts, :repo, &DDD.Config.repo!/0)

    children =
      [DDD.EventBus, {DDD.Supervisor.Subscriber, Keyword.get(opts, :handlers, [])}] ++
        outbox(repo, Keyword.get(opts, :poller, [])) ++
        retention(repo, Keyword.get(opts, :retention, false))

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp retention(_repo, false), do: []
  defp retention(repo, options), do: [{DDD.Outbox.Pruner, Keyword.put(options, :repo, repo)}]

  defp outbox(_repo, false), do: []

  defp outbox(repo, poller) do
    [
      {DDD.Outbox.Poller,
       Keyword.merge([interval_ms: 500, batch_size: 100], poller) |> Keyword.put(:repo, repo)},
      {DDD.Outbox.DeadLetterHandler, repo: repo}
    ]
  end
end
