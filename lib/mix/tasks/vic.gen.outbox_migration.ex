defmodule Mix.Tasks.Vic.Gen.OutboxMigration do
  @shortdoc "Generates the domain_events outbox table migration"
  @moduledoc """
  Generates an Ecto migration for the DDD outbox `domain_events` table.

      mix vic.gen.outbox_migration
  """

  use Mix.Task

  def run(_args) do
    # The repo comes from the application's config, which needs the project compiled: without
    # this a fresh checkout fails with "no repo configured" until `mix compile` has been run.
    Mix.Task.run("compile")

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_create_domain_events.exs"
    path = Path.join(["priv", "repo", "migrations", filename])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, migration_content())
    Mix.shell().info([:green, "* created ", :reset, path])
  end

  # A partial index speeds up the poller's and the dead letters' queries on Postgres. MySQL has
  # none: it does without, and says so in the migration.
  defp partial_index(repo, columns, where, name) do
    if repo.__adapter__() == Ecto.Adapters.Postgres do
      pad = String.duplicate(" ", 13)

      "create index(:domain_events, #{columns},\n" <>
        "#{pad}where: #{inspect(where)},\n" <>
        "#{pad}name: :#{name}\n" <> String.duplicate(" ", 11) <> ")"
    else
      "# #{name}: a partial index, which MySQL does not have"
    end
  end

  defp migration_content do
    repo = DDD.Config.repo!()

    """
    defmodule #{inspect(DDD.Config.repo!())}.Migrations.CreateDomainEvents do
      use Ecto.Migration

      def change do
        create table(:domain_events, primary_key: false) do
          add :id,             :binary_id,         primary_key: true
          add :event_type,     :string,            null: false
          add :aggregate_id,   :string,            null: false
          add :aggregate_type, :string,            null: false
          add :payload,        :map,               null: false
          add :occurred_at,    :utc_datetime_usec, null: false
          add :published_at,   :utc_datetime_usec, null: true

          # Retry bookkeeping and the lease that keeps two pollers from taking one event.
          add :attempts,        :integer,           null: false, default: 0
          add :last_error,      :text
          add :next_attempt_at, :utc_datetime_usec
          add :locked_until,    :utc_datetime_usec
          # Set after too many failed attempts (dead letter): no longer claimed.
          add :failed_at,       :utc_datetime_usec

          # What happened to a dead letter ("kept" or "discarded"), and how often it was replayed.
          add :resolution,      :string
          add :resolved_at,     :utc_datetime_usec
          add :replays,         :integer,           null: false, default: 0
          timestamps(updated_at: false)
        end

        create index(:domain_events, [:published_at])
        create index(:domain_events, [:aggregate_id])
        create index(:domain_events, [:aggregate_type])
        create index(:domain_events, [:occurred_at])

        #{partial_index(repo, "[:occurred_at]", "published_at IS NULL AND failed_at IS NULL", "domain_events_pending_index")}

        # Which handler already processed which event: a retry skips handlers that succeeded.
        create table(:event_deliveries, primary_key: false) do
          add :event_id, references(:domain_events, type: :binary_id, on_delete: :delete_all),
            null: false

          add :handler,      :string,            null: false
          # "delivered", or "rejected" when the handler answered with a business error.
          add :outcome,      :string,            null: false, default: "delivered"
          add :reason,       :text
          add :delivered_at, :utc_datetime_usec, null: false
        end

        create unique_index(:event_deliveries, [:event_id, :handler])

        #{partial_index(repo, "[:failed_at]", "failed_at IS NOT NULL AND resolved_at IS NULL", "domain_events_unresolved_dead_letters_index")}
      end
    end
    """
  end
end
