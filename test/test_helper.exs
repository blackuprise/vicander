# The framework is a library and starts nothing itself, so the tests start what an application
# would: the repo, and the event bus (`DDD.Supervisor` is tested on its own).
{:ok, supervisor} =
  Supervisor.start_link([DDD.TestRepo, DDD.EventBus],
    strategy: :one_for_one,
    name: DDD.TestSupervisor
  )

Process.unlink(supervisor)

ExUnit.start()
