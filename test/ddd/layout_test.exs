defmodule DDD.LayoutTest do
  @moduledoc """
  How `lib/ddd` is organised: folders by concern, one module per file, and a file named after
  its module. The module names do not follow the folders (`lib/ddd/model/entity.ex` defines
  `DDD.Entity`): the public API stays short, the folders are for finding things.
  """
  use ExUnit.Case, async: true

  @root "lib/ddd"
  @folders ~w(events mcp model operations persistence use_cases)

  defp files, do: Path.wildcard("#{@root}/**/*.ex")

  defp modules(file),
    do: for([_, name] <- Regex.scan(~r/^defmodule\s+(\S+)\s+do/m, File.read!(file)), do: name)

  test "the framework is grouped into folders by concern" do
    folders =
      "#{@root}/*" |> Path.wildcard() |> Enum.filter(&File.dir?/1) |> Enum.map(&Path.basename/1)

    assert Enum.sort(folders) == @folders
  end

  test "only the MCP core sits beside its folder; nothing else is loose" do
    assert Path.wildcard("#{@root}/*.ex") == ["#{@root}/mcp.ex"]
  end

  test "every file holds exactly one module, in the DDD namespace" do
    for file <- files() do
      assert [name] = modules(file), "#{file} defines #{inspect(modules(file))}"
      assert name == "DDD" or String.starts_with?(name, "DDD."), "#{file}: #{name}"
    end
  end

  test "a file is named after its module" do
    for file <- files() do
      [name] = modules(file)
      expected = name |> String.split(".") |> List.last() |> Macro.underscore()
      assert Path.basename(file, ".ex") == expected, "#{file} defines #{name}"
    end
  end

  test "no module is defined twice" do
    all = Enum.flat_map(files(), &modules/1)
    assert all == Enum.uniq(all)
  end
end
