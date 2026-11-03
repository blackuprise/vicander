# Changelog

All notable changes to `vicander` (the `DDD.*` modules). The project follows
[Semantic Versioning](https://semver.org); until 1.0, a minor version may change the API.

## 0.1.1 - 2026-11-03

The first version on Hex. `0.1.0` was only a git tag, and its CI failed on a formatting check.

### Added

* **Your own Ecto schema.** `use DDD.Repository.Ecto, ..., schema: MyApp.OrderRecord` stores an
  aggregate in a table you already have (instead of `table:`; both is an error). Fields map by
  name; override `to_domain/1` / `from_domain/1` (or call `to_domain/2` / `from_domain/2` with the
  fields that differ) for the rest. The save stays the framework's (your `changeset/2` is never
  called). The schema is checked when the adapter compiles (`:version`, primary key, JSON
  columns, unmapped fields). `mix vic.gen.migration` skips such aggregates;
  `DDD.Migration.schema_drift/2` and `DDD.Migration.table_drift/1` report a mismatch.

### Changed (breaking)

* **The framework is a library.** It starts nothing and reads nothing from your own
  application's configuration. Configure `config :vicander, repo: MyApp.Repo` and put
  `{DDD.Supervisor, handlers: [...]}` in your supervision tree. `Vicander.Repo` and
  `Vicander.Application` are gone; the default repo of commands, queries, handlers,
  projections and the Mix tasks is the configured one.
* **Mix tasks are `mix vic.*`** (they were `mix ddd.*`): `vic.gen.migration`,
  `vic.gen.outbox_migration`, `vic.outbox.dead_letters`, `vic.outbox.replay`,
  `vic.outbox.discard`, `vic.health`, `vic.projection.rebuild`, `vic.mcp`.
* **Identity.** Several fields can form an identity (`identity :tenant_id, :uuid` and
  `identity :sku, :string`); `Entity.identity/1` is its string. Every part is required and
  immutable, and only a lone `identity :id, :uuid` is generated (as a UUIDv7).
* Field values are type-checked (`:invalid_type`), and command/query fields are typed.
* `DDD.Error` has `entity_id`.
* `update/2` refuses a struct the framework did not produce, and an aggregate's pending events
  are part of its seal.
* **Nested lists are one `jsonb` column.** `{:list, Entity}` (and arrays of nested entities or
  maps) used to be a Postgres array of `jsonb` (`jsonb[]`); they are now a single `jsonb` array.
  Existing tables need `ALTER TABLE t ALTER COLUMN c TYPE jsonb USING to_jsonb(c)`; the example
  app has the migration. The migration generator reports the column as changed.
* **`postgrex` is no longer a dependency** of the library: the application picks its driver.
  `ecto_sql` stays (the outbox calls `repo.query!`).

### Added

* `DDD.Supervisor`, `DDD.Config`.
* `DDD.Query` (read-only transactions), `DDD.Filter`, `DDD.Listing`, `DDD.Page`, `DDD.Slice`.
* Field types: `:text`, `:time`, `:naive_datetime`, `:binary`, `:json`, `{:array, t}`,
  `{:enum, [...]}`, `{:map, t}`, `{:ref, Aggregate}`, `:money` (`DDD.Money`).
* Optimistic locking (`version`, `:stale_aggregate`, `retry_on_conflict:`), `DDD.Projection`,
  `DDD.Health`, `DDD.Telemetry`.
* `DDD.MCP`: the application as a Model Context Protocol server (`mix vic.mcp`).
* `DDD.Dialect`: the few database-specific operations (claim lock, database clock, read-only
  transaction, column introspection) behind a behaviour chosen from the repo's adapter
  (`DDD.Dialect.Postgres`), or set with `config :vicander, dialect: MyDialect`. The outbox,
  dead letters, retention, projections, telemetry and health are Ecto queries over
  `DDD.Outbox.Event` and `DDD.Outbox.Delivery` instead of raw SQL. Event ids that the outbox
  functions (`DDD.EventHandler.deliver/4`, `DDD.Outbox.Poller.claim/3`) take and return are now
  the UUID string, not the 16-byte binary. Leases and retry times use the database clock.
* `DDD.Migration.drift/3` looks at the schemas on the search path, not at every table of that name.
* `DDD.Outbox.Retention` (`mix vic.outbox.prune`, `retention:` of the supervisor).
* `DDD.Test`: `assert_event_emitted/3`, `refute_event_emitted/3`, `assert_error_code/2`,
  `drain_outbox/1`.
* `description` on commands, queries, entities and fields; value specifications bound to a field
  (`invariant Spec, on: :field`).
* The formatter configuration exports the DSL (`import_deps: [:vicander]`).
* Development checks: Credo (`mix credo --strict`) and Dialyzer (`mix dialyzer`), both dev-only
  dependencies, run in CI.

### Fixed

* Delivery of an event no longer crashes the poller; a failing event is retried and then
  dead-lettered. A handler whose nested transaction rolled back is retried.
* Blank strings are stored as they are (not as NULL); a malformed id is "not found".
