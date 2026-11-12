# Changelog

All notable changes to `vicander` (the `DDD.*` modules). The project follows
[Semantic Versioning](https://semver.org); until 1.0, a minor version may change the API.

## 0.4.0 - 2026-11-12

### Added

* **MCP over HTTP: `DDD.MCP.HTTP`**, a Plug that serves a `DDD.MCP.Server` to many remote clients
  (`POST` of one JSON-RPC message, a JSON reply, `202` for notifications; no streaming, no
  session). It refuses other methods (`405`), batches, an unsupported `MCP-Protocol-Version`
  (`400`) and an `Origin` that is not in `allowed_origins` (`403`, against DNS rebinding).
  Authentication is the application's: `authenticate:` (required; `:none` for development) turns
  a bearer token into a context or `{:error, :invalid_token}`, and a missing or invalid token gets
  `401` with a `WWW-Authenticate: Bearer` header carrying `resource_metadata` (RFC 9728). The
  optional `authorize_request:` answers `403 insufficient_scope` for what the token's scope
  forbids. `plug` is an optional dependency.
* **The caller's context reaches `authorize:`.** A function of three arguments,
  `(tool, arguments, context)`, gets what the transport knows about who is asking. A function of
  two arguments works as before, and `handle/2` of a server takes the context (`%{}` over stdio).
  `DDD.MCP.protocol_versions/0` lists the versions the server speaks.

## 0.3.0 - 2026-11-11

### Breaking

* **Newer dependencies.** `ecto ~> 3.14`, `ecto_sql ~> 3.14` and `decimal ~> 3.2`. The old
  `decimal ~> 2.0` requirement kept applications on ecto 3.13.6 and decimal 2.4.1, which have
  published security advisories.
* **`elixir_uuid` is no longer a dependency** (its last release was in 2019). `DDD.Identity`
  loses `uuid1/0`, `uuid3/2`, `uuid4/0` and `uuid5/2`, which only delegated to it; `uuid7/0` and
  `generate/0` are unchanged. Use `Ecto.UUID.generate/0` for a random v4. Event ids are now
  UUIDv7 (they were v4), so the outbox table's primary key is time-ordered.
* **A handler gets the event with the types it was declared with.** `field :status, :atom`,
  `:decimal`, `:date`, `:datetime` and enum fields used to come back from the outbox as the text
  they were stored as; now they are an atom, a `Decimal`, a `Date`, a `DateTime`. The event macro
  keeps each field's type, the payload is stored with `DDD.Type.json_dump/2` and read with
  `json_load/2`. A value that does not load (a row written by hand, or before the field had its
  type) is delivered as stored, with a warning. Code that matched the old text form must change.
  An event that changes in a way old rows can not be read as gets a new module (`OrderPlacedV2`).
* **An in-memory repository's `count` and `all` raise after a save in a unit of work**, as the
  Ecto adapter's queries do (`DDD.UnitOfWork.PendingChangesError`). A test that saved and then
  counted passed against the in-memory repository and failed in production; now it fails in both.

### Added

* **`sensitive: true` on command, query and event fields.** The struct leaves the field out of
  `inspect/1`, so debug logs, crash reports and IEx do not show it. The debug lines of commands
  and queries now log the struct (`inspect(command)`), not a plain map of its fields. The value is
  still in the struct and reaches `execute/1`; an event's stored payload still holds it.
* **The outbox renews the lease of a batch.** A batch can take longer than its lease; before each
  event the poller now renews the lease of the rest of its aggregate's events once half of it has
  passed (no query while handlers are fast), so another node does not claim an event whose
  handler is still running. See "Delivery guarantees" in the README for what each kind of
  handler can promise, with advice for handlers that publish to Kafka.

### Changed

* **`required: true` is `NOT NULL` in a generated table.** `mix vic.gen.migration` writes
  `null: false` for the column when it creates a table. A column added to an existing table stays
  nullable, as adding a `NOT NULL` column to a table with rows fails, and neither the diff nor the
  drift check reports an existing table as changed. Tables generated earlier need a hand-written
  migration to add the constraint.
* **The `@doc` above a `defop` is the operation's documentation and description.** It is shown by
  IEx and ExDoc and read by the MCP server (`@doc false` hides the operation). It used to be
  discarded silently. `defop ..., description: "..."` still works when there is no `@doc` but is
  deprecated and warns at compile time.
* **Unknown event types are rejected about 100 times faster.** The poller looked a type up by
  listing every available module (about 20 ms); it now looks for the module's file. A backlog of
  events of a removed type no longer costs seconds of scanning per poll.

### Fixed

* `mix vic.gen.outbox_migration` compiles the project first, so it works on a fresh checkout
  without a separate `mix compile`.
* The README no longer lists "Concurrent first saves" as a gap: two commands that save the same
  new id at once get one success and one `:stale_aggregate` (now covered by a test).
* The README explains `impl/0` on a repository port (it is written by hand, on purpose), and the
  errors that ask for it say so.

## 0.2.0 - 2026-11-06

### Changed

* **The outbox poller drains a backlog at the speed of the handlers.** It used to sleep
  `interval_ms` after every batch, so a backlog drained at `batch_size / interval_ms`. It now
  polls again at once while batches come back full and sleeps only when idle. The default
  `interval_ms` is 3 seconds (was 500 ms) and the default `batch_size` is 20 (was 100).
* **Different aggregates are delivered concurrently** (`poller: [concurrency: 4]`); the events of
  one aggregate stay in order. A projection can no longer rely on `occurred_at` order across
  aggregates. The poller warns at start-up when `concurrency` is not below the repo's pool size.
* **A batch is marked published with one statement**, and claiming it takes two statements
  instead of three.
* **An aggregate's events are written with one `INSERT`**, not one per event.
* **`retry_on_conflict` waits a random time before each retry** (up to 5 ms, doubling to 200 ms),
  so commands that lose a race on a hot aggregate stop colliding again. The
  `[:ddd, :command, :retry]` telemetry event has a `delay_ms` measurement. In a test with 20
  workers on one row, re-runs per success fell from about 6 to about 1.
* **Per-operation log lines are `debug`** (a command or query starting and finishing, a repository
  save, an event published). Failures and retries are still logged at `info` or above.

### Changed (breaking)

* **Commands run in a unit of work** (`DDD.UnitOfWork`). Inside a command or a transactional
  event handler, `find_by_id` loads an aggregate once, `save` and `delete` are recorded and
  written when the outermost command ends (before its transaction commits), and only changed
  aggregates are written. See "Unit of work" in the README. What changes for you:
  * a lost race is reported at the end of the command, not at the `save` call (still
    `:stale_aggregate`, still retried by `retry_on_conflict`);
  * a query by anything but the id (`find_by_*`, `list`, `page`, `slice`, `count`) raises
    `DDD.UnitOfWork.PendingChangesError` after the command has saved or deleted something;
  * a command with `transaction: false` that fails writes nothing from its repositories;
  * `save` returns the aggregate at the version it will have, before it is written.

  Opt out per command with `use DDD.Command, unit_of_work: false`. Code outside a command or a
  handler is unchanged.
* **Writes are batched** (Postgres): one `INSERT` for the new aggregates, one versioned
  `UPDATE ... FROM (VALUES ...)` for the changed ones, one versioned `DELETE`, and one `INSERT`
  of all their events. A command that changes 20 aggregates went from 82 queries to 24 (and
  from about 28 ms to about 17 ms); the 20 reads are what is left. `delete` is now guarded by
  the version, like `save`. An aggregate that only emitted events is not rewritten but its
  version is checked. A database without batched writes is written one aggregate at a time.
* **`:stale_aggregate` lists every conflict** in `details.conflicts`; the first one is still in
  `details.id`, `expected_version` and `actual_version`.
* A flush of a `transaction: false` command is atomic: it opens a transaction of its own.
* New optional `DDD.Dialect` callbacks `insert_new/4`, `update_versioned/5` and
  `delete_versioned/4`; `DDD.Dialect.batch?/1` says whether a dialect has them.

* **An aggregate's `updated_at` is set when it is written**, not by its operations. An
  operation that changes nothing it stores (one that only emits an event) leaves the aggregate
  as it was, so it is checked but not rewritten. Entities are unchanged: their operations still
  bump `updated_at`.

* **`DDD.InMemoryRepository` hands off an aggregate's pending events on `save`**, as the database
  adapter does: what it stores, and returns, has none.
* **A deadlock is a retryable error.** A transaction the database aborts for a deadlock (or, on
  Postgres, a serialization failure) returns an infrastructure error with code
  `:deadlock_detected` instead of raising, and `retry_on_conflict` retries it like
  `:stale_aggregate`. Each dialect decides what is retryable (`retryable?/1`).
* **`use DDD.Command, flush_order: :sorted`** writes tables in name order and rows in key order,
  and locks the rows to change in key order first, so commands that all use it cannot deadlock
  each other over the rows they write. The default is the order the changes were recorded in.
  `DDD.UnitOfWork.run/2` takes the same option.

### Added

* **MySQL 8 support** (`DDD.Dialect.MyXQL`): the unit of work with batched writes, `loads:`, the
  outbox and the poller. Array columns are Postgres only. `mix vic.gen.outbox_migration` leaves
  out the partial indexes on MySQL. The tests run on both (`DB=mysql mix test --only mysql`), and
  CI has a MySQL job. See "Databases" in the README.
* **`loads: Aggregate` on a command field** (or `loads: true` on a `{:ref, Aggregate}` field)
  reads the declared aggregates with one query per repository before `execute/1`. Where an
  aggregate is stored is configured once with `config :vicander, :repositories`; a port (a module
  with `impl/0`) or an adapter can be named instead. A declared id that does not exist fails the
  command with a business `:not_found` error before it starts. With it, the 20-aggregate command
  above takes 5 queries (it took 82 at the start of this release). Not allowed with
  `unit_of_work: false`.
* A constraint the database enforces (unique, foreign key, check, not null) that a batched write
  breaks is returned as `:persistence_failed` (`details` has the kind, constraint and the
  database's message), not raised. A new aggregate whose *key* exists is still a
  `:stale_aggregate`; breaking another unique index is no longer mistaken for it. New optional
  `DDD.Dialect` callback `integrity_violation/1`.
* The version check of an aggregate that only emitted events locks the row (`FOR SHARE`) until
  the commit, so the events cannot be recorded for a state someone else has just changed.
* The poller survives a failure while marking a batch published: it logs it, emits
  `[:ddd, :outbox, :mark_failed]` and sleeps its interval. The events are marked when their
  lease ends; no handler runs again.
* `DDD.UnitOfWork.run/1`, to open a unit of work around code that is not a command.
* A `[:ddd, :unit_of_work, :flush]` telemetry span with the counts of what the flush wrote and
  how many aggregates the unit of work loaded from the database or from memory.
* `test/ddd/transaction_stress_test.exs`: real-commit concurrency test that checks for lost
  updates, lost or duplicated events and double claims, and prints a query-by-query report. Run
  it with `mix test --only stress`.

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
  functions (`DDD.EventHandler.deliver/4`, the poller's `claim/3`) take and return are now
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
