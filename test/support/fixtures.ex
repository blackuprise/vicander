defmodule DDD.Test.Account do
  @moduledoc "A small aggregate for the tests that need one (migration generation, tasks)."
  use DDD.Aggregate

  aggregate do
    description "A person's account"

    identity :id, :uuid
    field :name, :string, required: true, description: "The account holder"
    field :email, :string
    field :balance, :integer, default: 0
  end
end

defmodule DDD.Test.Ledger do
  @moduledoc "A second aggregate, for the tests that generate more than one migration."
  use DDD.Aggregate

  aggregate do
    identity :id, :uuid
    field :title, :string
    field :entries, {:array, :string}, default: []
  end
end
