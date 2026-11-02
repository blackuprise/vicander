defmodule DDD.TestRepo.Migrations.CreateTestUsers do
  use Ecto.Migration

  # A table for the tests that need a write they can look for (to see whether a handler's work
  # was rolled back, say).
  def change do
    create table(:test_users, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string)
      add(:email, :string)
      add(:created_at, :utc_datetime_usec)
      add(:updated_at, :utc_datetime_usec)
    end
  end
end
