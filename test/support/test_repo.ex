defmodule DDD.TestRepo do
  @moduledoc """
  The repo the framework's own tests run against (Postgres, or MySQL with `DB=mysql`; test only). Its migrations are in
  `test/support/repo/migrations`: the outbox tables, which an application generates with
  `mix vic.gen.outbox_migration`, and a small table the tests write to.
  """
  # `DB=mysql mix test --only mysql` runs the MySQL tests (see config/test.exs).
  @adapter (case Application.compile_env(:vicander, :test_db, :postgres) do
              :mysql -> Ecto.Adapters.MyXQL
              _postgres -> Ecto.Adapters.Postgres
            end)

  use Ecto.Repo, otp_app: :vicander, adapter: @adapter
end
