defmodule DDD.DoctestTest do
  # The examples in the documentation are run, so they stay true.
  use ExUnit.Case, async: true

  doctest DDD.Identity
  doctest DDD.Type
  doctest DDD.Money
end
