defmodule DDD.ConfigTest do
  # Not async: it changes the application environment.
  use ExUnit.Case, async: false

  alias DDD.Config

  setup do
    original = Application.fetch_env!(:vicander, :repo)
    on_exit(fn -> Application.put_env(:vicander, :repo, original) end)
    %{original: original}
  end

  test "repo!/0 is the configured repo", %{original: original} do
    assert Config.repo!() == original
    Application.put_env(:vicander, :repo, Some.Other.Repo)
    assert Config.repo!() == Some.Other.Repo
  end

  test "repo!/0 says how to configure it when it is missing" do
    Application.delete_env(:vicander, :repo)

    error = assert_raise ArgumentError, fn -> Config.repo!() end
    assert error.message =~ "config :vicander, repo: MyApp.Repo"

    Application.put_env(:vicander, :repo, nil)
    assert_raise ArgumentError, fn -> Config.repo!() end
  end

  test "repo/1 resolves :default, keeps nil and modules" do
    assert Config.repo(:default) == Config.repo!()
    assert Config.repo(nil) == nil
    assert Config.repo(My.Repo) == My.Repo
  end

  test "it is read when the code runs, so a test can change it", %{original: original} do
    defmodule Late do
      use DDD.Command

      command do
        description "x"
      end

      def execute(_), do: {:ok, 1}
    end

    assert Late.__cmd_repo__() == original
    Application.put_env(:vicander, :repo, Another.Repo)
    assert Late.__cmd_repo__() == Another.Repo
  end
end
