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

  @doc false
  # The entity as it is stored, and as `save` returns it, like the database adapter does: one
  # version on, its pending events handed off (there is no outbox here, so they go nowhere), and
  # `updated_at` set when it replaces one that was stored already (a new one keeps the time
  # `new` gave it).
  def saved(entity, expected, replaces?) do
    bumped = entity |> Map.put(:version, expected + 1) |> without_events()
    DDD.Schema.seal(if replaces?, do: DDD.Schema.touch(bumped), else: bumped)
  end

  defp without_events(%{__pending_events__: _} = aggregate),
    do: %{aggregate | __pending_events__: []}

  defp without_events(entity), do: entity

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
      def find_by_id(id), do: DDD.UnitOfWork.read(__MODULE__, id, fn -> __load__(id) end)

      @doc false
      def __load__(id) do
        case Agent.get(__MODULE__, &Map.get(&1, id)) do
          nil -> {:error, :not_found}
          entity -> {:ok, entity}
        end
      end

      @doc false
      def __load_many__(ids) do
        for id <- ids, {:ok, entity} <- [__load__(id)], do: entity
      end

      @doc false
      def __aggregate__, do: unquote(port).__repo_aggregate__()

      @impl unquote(port)
      def save(entity), do: DDD.UnitOfWork.save(__MODULE__, entity, &__persist__/1)

      @doc false
      def __persist__(entity, opts \\ []) do
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
              stamp? = stored != nil and Keyword.get(opts, :stamp, true)
              saved = DDD.InMemoryRepository.saved(entity, expected, stamp?)

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
      def delete(entity), do: DDD.UnitOfWork.delete(__MODULE__, entity, &__remove__/1)

      @doc false
      def __remove__(entity) do
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
