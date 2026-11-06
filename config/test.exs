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

# `DB=mysql` points the same repo at MySQL, for the tests tagged `:mysql`:
#
#     docker run -d -e MYSQL_ROOT_PASSWORD=mysql -p 3306:3306 mysql:8.0
#     DB=mysql mix test --only mysql
if System.get_env("DB") == "mysql" do
  config :vicander, :test_db, :mysql

  config :vicander, DDD.TestRepo,
    username: "root",
    password: System.get_env("MYSQL_PASSWORD", "mysql"),
    hostname: System.get_env("MYSQL_HOST", "127.0.0.1"),
    port: String.to_integer(System.get_env("MYSQL_PORT", "3306"))
else
  config :vicander, :test_db, :postgres
end
