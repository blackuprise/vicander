defmodule DDD.Test.Sensitive do
  @moduledoc false
  # Modules with `sensitive: true` fields. They live here and not in a test file because a
  # derived `Inspect` only takes effect for a module compiled before the protocol is
  # consolidated, as an application's own modules are.

  defmodule Register do
    @moduledoc false
    use DDD.Command, transaction: false

    command do
      field :email, :string, required: true
      field :password, :string, required: true, sensitive: true
    end

    @impl DDD.Command
    def execute(%__MODULE__{password: password}), do: {:ok, String.length(password)}
  end

  defmodule Lookup do
    @moduledoc false
    use DDD.Query, transaction: false

    query do
      field :email, :string, required: true
      field :token, :string, sensitive: true
    end

    @impl DDD.Query
    def execute(%__MODULE__{token: token}), do: {:ok, token}
  end

  defmodule Plain do
    @moduledoc false
    use DDD.Command, transaction: false

    command do
      field :note, :string
    end

    @impl DDD.Command
    def execute(_), do: {:ok, :done}
  end

  defmodule Paid do
    @moduledoc false
    use DDD.DomainEvent

    domain_event do
      field :order_id, :string
      field :card, :string, sensitive: true
    end
  end
end
