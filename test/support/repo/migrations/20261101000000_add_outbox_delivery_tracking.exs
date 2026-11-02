defmodule DDD.TestRepo.Migrations.AddOutboxDeliveryTracking do
  use Ecto.Migration

  def change do
    alter table(:domain_events) do
      # Retry bookkeeping: delivery attempts, the last failure, when to retry, and the
      # lease that keeps two pollers from taking the same event.
      add(:attempts, :integer, null: false, default: 0)
      add(:last_error, :text)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:locked_until, :utc_datetime_usec)
      # Set after too many failed attempts (dead letter): the event is no longer claimed.
      add(:failed_at, :utc_datetime_usec)
    end

    create(
      index(:domain_events, [:occurred_at],
        where: "published_at IS NULL AND failed_at IS NULL",
        name: :domain_events_pending_index
      )
    )

    # Which handler already processed which event, so a retry skips the handlers that
    # succeeded and only re-runs the ones that failed.
    create table(:event_deliveries, primary_key: false) do
      add(:event_id, references(:domain_events, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:handler, :string, null: false)
      add(:delivered_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:event_deliveries, [:event_id, :handler]))
  end
end
