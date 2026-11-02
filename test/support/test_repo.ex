defmodule DDD.TestRepo do
  @moduledoc """
  The repo the framework's own tests run against (Postgres, test only). Its migrations are in
  `test/support/repo/migrations`: the outbox tables, which an application generates with
  `mix vic.gen.outbox_migration`, and a small table the tests write to.
  """
  use Ecto.Repo, otp_app: :vicander, adapter: Ecto.Adapters.Postgres
end
