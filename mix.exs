defmodule Vicander.MixProject do
  use Mix.Project

  def project do
    [
      app: :vicander,
      version: "0.1.1",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Domain-Driven Design framework for Elixir: entities, aggregates, specifications, " <>
          "commands, queries, an event outbox, projections and an MCP server",
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs(),
      package: package(),
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:mix, :ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      # Project standards: no compile warnings, at least 90% test coverage.
      elixirc_options: [warnings_as_errors: true],
      test_coverage: [summary: [threshold: 90]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # A library: it starts nothing. An application puts `{DDD.Supervisor, ...}` in its own tree.
  def application do
    # ExUnit is optional: `DDD.Test` (assertions for an application's tests) uses it when present.
    [extra_applications: [:logger, :crypto, ex_unit: :optional]]
  end

  defp deps do
    [
      {:decimal, "~> 2.0"},
      {:elixir_uuid, "~> 1.2"},
      {:ecto, "~> 3.11"},
      # Needed at run time (the outbox and the repositories call `repo.query!`), so it is a
      # dependency. The database driver is the application's choice: it adds `postgrex`.
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0", only: :test},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      # Static checks, development only: `mix credo --strict` and `mix dialyzer`.
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"}
    ]
  end

  # The files that go to Hex.
  defp package do
    [
      name: "vicander",
      licenses: ["Apache-2.0"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      links: %{"GitHub" => "https://github.com/blackuprise/vicander"}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Model: [
          DDD.Entity,
          DDD.Aggregate,
          DDD.ValueObject,
          DDD.Identity,
          DDD.Specification,
          DDD.Error,
          DDD.Type,
          DDD.Money,
          DDD.BoundedContext,
          DDD.DomainService
        ],
        "Use cases": [
          DDD.Command,
          DDD.Query,
          DDD.Params,
          DDD.Filter,
          DDD.Listing,
          DDD.Page,
          DDD.Slice
        ],
        Events: [
          DDD.DomainEvent,
          DDD.EventBus,
          DDD.EventHandler,
          DDD.Supervisor,
          ~r/DDD\.Outbox/
        ],
        Persistence: [
          DDD.Repository,
          DDD.Repository.Ecto,
          DDD.InMemoryRepository,
          DDD.Projection,
          DDD.Migration,
          DDD.Serializer
        ],
        MCP: [~r/DDD\.MCP/],
        Operations: [DDD.Config, DDD.Health, DDD.Telemetry]
      ]
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
