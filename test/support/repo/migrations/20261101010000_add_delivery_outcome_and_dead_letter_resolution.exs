defmodule DDD.TestRepo.Migrations.AddDeliveryOutcomeAndDeadLetterResolution do
  use Ecto.Migration

  def change do
    alter table(:event_deliveries) do
      # "delivered", or "rejected" when the handler answered with a business error. A
      # rejection is remembered so the handler is not run again for that event.
      add(:outcome, :string, null: false, default: "delivered")
      add(:reason, :text)
    end

    alter table(:domain_events) do
      # What happened to a dead letter: "kept" (acknowledged and left as is), "discarded".
      # A replay clears the failure state instead, and counts in `replays`.
      add(:resolution, :string)
      add(:resolved_at, :utc_datetime_usec)
      add(:replays, :integer, null: false, default: 0)
    end

    if repo().__adapter__() == Ecto.Adapters.Postgres do
      create(
        index(:domain_events, [:failed_at],
          where: "failed_at IS NOT NULL AND resolved_at IS NULL",
          name: :domain_events_unresolved_dead_letters_index
        )
      )
    end
  end
end
