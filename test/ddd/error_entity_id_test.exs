defmodule DDD.ErrorEntityIdTest do
  @moduledoc "An error says which instance it happened to, not only which kind of entity."
  use ExUnit.Case, async: true

  alias DDD.{Error, Identity}

  defmodule IsClosed do
    use DDD.Specification

    @impl DDD.Specification
    def check(%{status: :closed}, _opts), do: :ok
    def check(_ticket, _opts), do: {:error, :not_closed, "only a closed ticket can be reopened"}
  end

  defmodule Ticket do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :title, :string, required: true
      field :status, {:enum, [:open, :closed]}, default: :open
      field :points, :integer, default: 1

      validate :points, &(&1 > 0), message: "must be positive"
    end

    defop close(%{status: :open} = ticket), do: %{ticket | status: :closed}

    defop reopen(ticket), requires: IsClosed do
      %{ticket | status: :open}
    end

    defop move(ticket, id), do: %{ticket | id: id}
    defop grow(ticket, points), do: %{ticket | points: ticket.points + points}
  end

  defmodule Seat do
    use DDD.Aggregate

    aggregate do
      identity :room, :string
      identity :number, :integer
      field :taken, :boolean, default: false
    end

    defop take(seat), do: %{seat | taken: true}
  end

  defp ticket!(attrs \\ []) do
    {:ok, ticket} = Ticket.new(Keyword.merge([title: "a"], attrs))
    ticket
  end

  describe "the error carries the identity of the instance" do
    test "validation on update" do
      ticket = ticket!()
      assert {:error, %Error{entity: Ticket} = error} = Ticket.update(ticket, points: 0)
      assert error.entity_id == ticket.id
      assert error.code == :validation_failed
    end

    test "validation of an operation's result" do
      ticket = ticket!()
      assert {:error, error} = Ticket.grow(ticket, -5)
      assert error.entity_id == ticket.id
    end

    test "validation on new: the id the entity was given, if it has one" do
      assert {:error, error} = Ticket.new(%{})
      assert {:ok, _} = Ecto.UUID.cast(error.entity_id)

      id = UUID.uuid4()
      assert {:error, error} = Ticket.new(id: id)
      assert error.entity_id == id
    end

    test "an operation that is not allowed in the current state" do
      {:ok, closed} = Ticket.close(ticket!())
      assert {:error, %Error{code: :invalid_operation} = error} = Ticket.close(closed)
      assert error.entity_id == closed.id
    end

    test "an operation that changes the identity" do
      ticket = ticket!()
      assert {:error, %Error{code: :identity_changed} = error} = Ticket.move(ticket, UUID.uuid4())
      assert error.entity_id == ticket.id
    end

    test "a struct that was not produced by the framework" do
      ticket = ticket!()
      tampered = %{ticket | title: "tampered"}

      assert {:error, %Error{code: :unsealed} = error} = Ticket.close(tampered)
      assert error.entity_id == ticket.id

      assert {:error, %Error{code: :unsealed} = error} = Ticket.update(tampered, points: 2)
      assert error.entity_id == ticket.id

      assert %Error{entity_id: id} = DDD.Schema.unsealed_error(tampered)
      assert id == ticket.id
    end

    test "a composite identity is the joined string" do
      {:ok, seat} = Seat.new(room: "A:1", number: 7)
      assert {:error, error} = Seat.update(seat, &%{&1 | number: 8})
      assert error.entity_id == "A\\:1:7"
      assert error.entity_id == Seat.identity(seat)
    end

    test "preconditions name the instance" do
      ticket = ticket!()

      assert {:error, %Error{code: :precondition_failed} = error} = Ticket.reopen(ticket)
      assert error.entity == Ticket
      assert error.entity_id == ticket.id

      {:ok, closed} = Ticket.close(ticket)
      assert {:ok, %{status: :open}} = Ticket.reopen(closed)
    end

    test "an error that has no instance has none" do
      assert Error.business(code: :x).entity_id == nil
      assert Error.wrap(:nope, %{}).entity_id == nil
    end
  end

  describe "the repositories name the instance too" do
    test "refusing to save an unsealed aggregate" do
      ticket = ticket!()
      assert %Error{entity_id: id} = DDD.Schema.unsealed_error(%{ticket | title: "x"})
      assert id == ticket.id
    end

    test "a lost update (optimistic locking) and a failed save" do
      assert %Error{entity: Ticket, entity_id: "t-1", code: :stale_aggregate} =
               DDD.Repository.Ecto.stale_error(Ticket, "t-1", 1, 2)
    end
  end

  describe "DDD.Identity.id_of/1" do
    test "is nil when there is nothing to name, and never raises" do
      assert Identity.id_of(nil) == nil
      assert Identity.id_of(%{id: 1}) == nil
      assert Identity.id_of(%Date{year: 2030, month: 1, day: 1, calendar: Calendar.ISO}) == nil

      {:ok, money} = DDD.Money.of(1, "EUR")
      assert Identity.id_of(money) == nil

      ticket = ticket!()
      assert Identity.id_of(%{ticket | id: nil}) == nil
      assert Identity.id_of(%{ticket | id: %{not: "text"}}) == nil
      assert Identity.id_of(ticket) == ticket.id
    end
  end
end
