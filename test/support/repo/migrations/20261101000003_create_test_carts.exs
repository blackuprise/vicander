defmodule DDD.TestRepo.Migrations.CreateTestCarts do
  use Ecto.Migration

  # The table of the `Cart` aggregate in the command transaction tests (what
  # `mix vic.gen.migration` would write for it).
  def change do
    create table(:test_carts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, :binary_id)
      add(:name, :string)
      add(:version, :integer)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end
  end
end
