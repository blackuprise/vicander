defmodule DDD.Repository do
  @moduledoc """
  Port (interface) for DDD Repositories.

  Declares base callbacks and domain-specific queries via `find_by`.
  The infrastructure layer provides the concrete Ecto adapter.

  ## Usage

      defmodule MyApp.OrderRepository do
        use DDD.Repository

        repo MyApp.Order do
          find_by :customer_id
          find_by :status
          find_by [:customer_id, :status]
        end
      end

  Generated callbacks:
      find_by_id/1
      save/1
      delete/1
      find_by_customer_id/1
      find_by_status/1
      find_by_customer_id_and_status/2
  """

  @callback find_by_id(id :: any()) :: {:ok, struct()} | {:error, :not_found}
  @callback save(aggregate :: struct()) :: {:ok, struct()} | {:error, any()}
  @callback delete(aggregate :: struct()) :: :ok | {:error, any()}

  defmacro __using__(_opts) do
    quote do
      import DDD.Repository, only: [repo: 2, find_by: 1]
      @repo_aggregate nil
      @repo_find_bys []
      @before_compile DDD.Repository
    end
  end

  defmacro repo(aggregate_module, do: block) do
    quote do
      @repo_aggregate unquote(aggregate_module)
      unquote(block)
    end
  end

  defmacro find_by(fields) do
    fields = List.wrap(fields)

    quote do
      @repo_find_bys [unquote(fields) | @repo_find_bys]
    end
  end

  defmacro __before_compile__(env) do
    find_bys = Module.get_attribute(env.module, :repo_find_bys) || []

    finder_callbacks =
      for fields <- find_bys do
        fn_name =
          fields
          |> Enum.map_join("_and_", &Atom.to_string/1)
          |> then(&:"find_by_#{&1}")

        args = Enum.map(fields, fn _ -> quote(do: any()) end)

        quote do
          @callback unquote(fn_name)(unquote_splicing(args)) :: [struct()]
        end
      end

    quote do
      @callback find_by_id(any()) :: {:ok, struct()} | {:error, :not_found}
      @callback save(struct()) :: {:ok, struct()} | {:error, any()}
      @callback delete(struct()) :: :ok | {:error, any()}

      # Listing: an adapter that can query (the Postgres one) provides these; a port's callers
      # can then use them without naming the adapter. See `DDD.Listing` for the options.
      @callback list(keyword()) :: {:ok, [struct()]} | {:error, DDD.Error.t()}
      @callback page(keyword()) :: {:ok, DDD.Page.t()} | {:error, DDD.Error.t()}
      @callback slice(keyword()) :: {:ok, DDD.Slice.t()} | {:error, DDD.Error.t()}
      @callback count(keyword()) :: {:ok, non_neg_integer()} | {:error, DDD.Error.t()}
      @optional_callbacks list: 1, page: 1, slice: 1, count: 1

      unquote_splicing(finder_callbacks)

      def __repo_aggregate__, do: @repo_aggregate
      def __repo_find_bys__, do: Enum.reverse(@repo_find_bys)
    end
  end
end
