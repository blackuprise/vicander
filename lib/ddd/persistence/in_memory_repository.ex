defmodule DDD.InMemoryRepository do
  @moduledoc """
  Generic in-memory repository adapter. Ideal for tests.

  ## Usage

      defmodule MyApp.Test.OrderRepository do
        use DDD.InMemoryRepository,
          port: MyApp.OrderRepository
      end

  Entities are stored under `DDD.Identity.key/1`: the identity field's value, or the identity
  string for a composite identity (the argument of `find_by_id/1`).

      {:ok, _} = MyApp.Test.OrderRepository.start_link()
  """

  defmacro __using__(opts) do
    port = Keyword.fetch!(opts, :port)

    quote do
      @behaviour unquote(port)
      use Agent

      # Accepts a map or keyword list so `start_supervised(MyRepo)` (which passes `[]`) works.
      def start_link(initial \\ %{}) do
        Agent.start_link(fn -> Map.new(initial) end, name: __MODULE__)
      end

      @impl unquote(port)
      def find_by_id(id) do
        case Agent.get(__MODULE__, &Map.get(&1, id)) do
          nil -> {:error, :not_found}
          entity -> {:ok, entity}
        end
      end

      @impl unquote(port)
      def save(entity) do
        if DDD.Schema.sealed?(entity) do
          id = DDD.Identity.key(entity)

          # Same optimistic locking as the Ecto adapter: the version you loaded must still be
          # the stored one, and a save advances it.
          Agent.get_and_update(__MODULE__, fn state ->
            expected = Map.get(entity, :version) || 0
            stored = Map.get(state, id)
            actual = if stored, do: Map.get(stored, :version) || 0

            # New: nothing stored and version 0. Existing: the stored version is the loaded one.
            current? = if stored, do: actual == expected, else: expected == 0

            if current? do
              saved = entity |> Map.put(:version, expected + 1) |> DDD.Schema.seal()
              {{:ok, saved}, Map.put(state, id, saved)}
            else
              error = DDD.Repository.Ecto.stale_error(entity.__struct__, id, expected, actual)
              {{:error, error}, state}
            end
          end)
        else
          {:error, DDD.Schema.unsealed_error(entity)}
        end
      end

      @impl unquote(port)
      def delete(entity) do
        id = DDD.Identity.key(entity)
        Agent.update(__MODULE__, &Map.delete(&1, id))
        :ok
      end

      def all, do: Agent.get(__MODULE__, &Map.values(&1))
      def count, do: Agent.get(__MODULE__, &map_size(&1))
      def clear, do: Agent.update(__MODULE__, fn _ -> %{} end)
    end
  end
end
