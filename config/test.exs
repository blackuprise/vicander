import Config

config :vicander, ecto_repos: [DDD.TestRepo], repo: DDD.TestRepo

# Test output is quiet by default (warnings and errors only).
# `LOG=1 mix test` shows the flow: commands, operations, repositories, outbox, events.
# Add `SQL=1` to also see the SQL queries.
config :logger, :default_handler, level: if(System.get_env("LOG"), do: :all, else: :warning)

config :vicander, DDD.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "vicander_test#{System.get_env("MIX_TEST_PARTITION")}",
  priv: "test/support/repo",
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQL queries are logged only with `SQL=1` (together with `LOG=1`).
  log: if(System.get_env("SQL"), do: :debug, else: false),
  pool_size: 10
