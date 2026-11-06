# The framework is a library and starts nothing itself, so the tests start what an application
# would: the repo, and the event bus (`DDD.Supervisor` is tested on its own).
{:ok, supervisor} =
  Supervisor.start_link([DDD.TestRepo, DDD.EventBus],
    strategy: :one_for_one,
    name: DDD.TestSupervisor
  )

Process.unlink(supervisor)

# `mix test --only stress` runs the slow concurrency tests (test/ddd/transaction_stress_test.exs).
# `DB=mysql mix test --only mysql` runs the MySQL tests (test/mysql); with `DB=mysql` the other
# tests, which use Postgres SQL, are left out.
if System.get_env("DB") == "mysql" do
  ExUnit.start(include: [:mysql], exclude: [:test])
else
  ExUnit.start(exclude: [:stress, :mysql])
end
