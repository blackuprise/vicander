defmodule DDD.DomainService do
  @moduledoc """
  Marker for Domain Services — stateless, domain-logic-only modules.

  ## Usage

      defmodule MyApp.Domain.PricingService do
        use DDD.DomainService

        def apply_discount(%Order{} = order, :gold),
          do: Decimal.mult(order.total.amount, "0.85")
        def apply_discount(%Order{} = order, _tier),
          do: order.total.amount
      end
  """

  defmacro __using__(_opts) do
    quote do
      def __ddd_type__, do: :domain_service
    end
  end
end
