defmodule DDD.TestRepo.Migrations.CreateDomainEvents do
  use Ecto.Migration

  def change do
    create table(:domain_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:event_type, :string, null: false)
      add(:aggregate_id, :string, null: false)
      add(:aggregate_type, :string, null: false)
      add(:payload, :map, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:published_at, :utc_datetime_usec, null: true)
      timestamps(updated_at: false)
    end

    create(index(:domain_events, [:published_at]))
    create(index(:domain_events, [:aggregate_id]))
    create(index(:domain_events, [:aggregate_type]))
    create(index(:domain_events, [:occurred_at]))
  end
end
