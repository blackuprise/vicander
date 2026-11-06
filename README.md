# Vicander

A Domain-Driven Design framework for Elixir, built on behaviours and macros: entities,
aggregates and value objects that **can never exist in an invalid state**, specifications,
commands and queries, a transactional event outbox, projections, and an MCP server so an AI
client can use the application. Its modules are `DDD.*`. The example application that uses it is
`todo_app` (a sibling project, `../todo_app`).

Field rules and specification invariants run on `new`, `update` and every business operation.

## Installation

```elixir
# mix.exs
def deps do
  [
    {:vicander, "~> 0.2"},
    # the database driver is yours to choose; PostgreSQL and MySQL 8 are supported
    {:postgrex, ">= 0.0.0"}
  ]
end
```

```elixir
# .formatter.exs: the DSL (`field :name, :string`) is written without parentheses
[import_deps: [:ecto, :ecto_sql, :vicander], inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]]
```

## Database

The framework depends on `ecto_sql` but not on a driver: your application adds the one it needs
(`postgrex`, ...), and `DDD.Dialect` follows from the repo's adapter. Almost everything is an
Ecto query, so it runs on whatever the repo runs on; the few things that differ between databases
are behind the `DDD.Dialect` behaviour:

| Ecto adapter             | Dialect                | Status    |
|--------------------------|------------------------|-----------|
| `Ecto.Adapters.Postgres` | `DDD.Dialect.Postgres` | supported (14 and later) |

For another adapter, implement `DDD.Dialect` (`lock_for_claim/1`, `now/1`, `read_only/2`,
`columns/2`) and set `config :vicander, dialect: MyApp.Dialect`. A repo with no dialect raises an
`ArgumentError` naming its adapter.

What is not portable yet:

* lists of plain values (`{:array, :string}`) are native Postgres arrays, and the `:ilike` filter
  is Postgres's `ILIKE`;
* the generated outbox migration has partial indexes (`where:`), which MySQL does not have.

Leases and retry times are compared with the **database's** clock (`c:DDD.Dialect.now/1`), so nodes
whose clocks differ still agree on when a lease is over. Nested entities, value objects and lists
of them are one `jsonb` column each.

## Setup

1. **Tell it your repo.** Commands, queries, handlers, projections and the `mix vic.*` tasks use
   the repo you configure, unless one names another with `repo:`:

   ```elixir
   # config/config.exs
   config :vicander, repo: MyApp.Repo
   ```

2. **Create the outbox tables**, once, and one migration per aggregate:

   ```bash
   mix vic.gen.outbox_migration
   mix vic.gen.migration MyApp.Domain.Order
   mix ecto.migrate
   ```

3. **Start the framework** in your supervision tree, after the repo. It starts the event bus,
   subscribes the handlers and projections you list, and runs the outbox poller and the
   dead-letter handler (`poller: false` for a node that should not deliver events, and in tests):

   ```elixir
   children = [
     MyApp.Repo,
     {DDD.Supervisor, handlers: [MyApp.Handlers.SendWelcome, MyApp.Projections.OrderSummary]}
   ]
   ```

The framework starts nothing by itself, and reads nothing from your application's own
configuration. See `DDD.Config` and `DDD.Supervisor`.

## Developing the framework

```bash
mix deps.get
mix test          # creates and migrates the test database; needs Postgres on localhost
mix credo --strict   # style and complexity (config in .credo.exs); dev only
mix dialyzer         # types; the first run builds a cache in priv/plts (a few minutes)
```

Postgres defaults for the tests live in `config/test.exs` (`postgres`/`postgres` on
`localhost`). The tests use `DDD.TestRepo` and the fixtures in `test/support`; the outbox tables
come from `test/support/repo/migrations`. Test output is quiet by default (warnings and errors
only). `LOG=1 mix test` shows the whole flow, and `LOG=1 mix test path/to/file_test.exs:LINE`
follows a single test:

```
[command] MyApp.Commands.CompleteItem started %{item_id: ..., list_id: ...}
[op] MyApp.Domain.TodoItem.complete ok
[op] MyApp.Domain.TodoList.complete_item ok
[repo] saved MyApp.Domain.TodoList <id> (1 event(s) written to the outbox)
[command] MyApp.Commands.CompleteItem ok in 7.8ms
[outbox] published MyApp.Events.ItemCompleted (MyApp.Domain.TodoList <id>)
[event_bus] MyApp.Events.ItemCompleted -> 1 handler(s): MyApp.Handlers.AchievementTracker
```

`[op]` and `[event_bus]` lines are `debug`, the rest `info`. Failed commands log the error codes
(`[command] ... failed in 3.1ms: title_blank (MyApp.Domain.TodoItem.new) ...`). SQL queries are
not shown unless you also set `SQL=1` (`LOG=1 SQL=1 mix test ...`). Tests that assert on a log
line use `capture_log`, so those stay captured.

## Project standards

* No compile warnings (`warnings_as_errors` is on).
* At least 90% test coverage (`mix test --cover` fails below the threshold).
* One module per file. In `lib/ddd` the file is named after its module and sits in a folder for
  its concern; the module names stay short (`DDD.Entity`), so the folders do not appear in them
  (`test/ddd/layout_test.exs` checks this):

  ```
  lib/ddd/
    model/         entity, aggregate, value_object, schema, identity, type, money,
                   specification, error, bounded_context, domain_service
    use_cases/     command, query, params, filter, listing, page, slice
    events/        domain_event, event_bus, event_handler, outbox/ (poller, dead letters)
    persistence/   repository, in_memory_repository, repository/ecto, migration, projection,
                   serializer
    mcp.ex, mcp/   the MCP server: protocol core, registry, schema, args, json, stdio
    operations/    health, telemetry
  ```

## Concepts

### Entity, aggregate, value object

```elixir
defmodule MyApp.Title do
  use DDD.ValueObject

  value_object do
    field :value, :string, required: true

    invariant MyApp.Specs.TitleWithinLimit, on: :value, max: 100
  end
end

defmodule MyApp.TodoItem do
  use DDD.Entity

  entity do
    identity :id, :uuid
    field :title, {:one, MyApp.Title}, required: true
    field :status, {:enum, [:open, :done]}, default: :open

    invariant MyApp.Specs.TitleNotBlank
  end

  defop complete(item), requires: MyApp.Specs.ItemNotCompleted do
    %{item | status: :done}
  end
end

{:ok, item} = MyApp.TodoItem.new(title: title)
{:ok, item} = MyApp.TodoItem.complete(item)
{:error, %DDD.Error{code: :precondition_failed} = error} = MyApp.TodoItem.complete(item)
DDD.Error.has_code?(error, :already_completed)   # => true
```

* `field name, type, default: ..., required: true`. Presence is `required: true`; every other
  rule is a specification attached with `invariant`. The example app has no `validate` at all.
  (`validate field, fun, message: ...` still exists as a shortcut for a throwaway one-liner,
  but it has no name, code or reuse, and it is skipped for `nil`.)
* `new/1`, `update/2` (attrs or a function of the current entity) and `validate/1` run all rules,
  and report every broken rule at once, each with its own code. Specs run after the required
  fields are present, so they only ever see a well-formed entity.
* `DDD.Aggregate` adds `emit_event/2` and `pop_events/1`. Nested entities are declared as
  `{:list, Entity}` or `{:one, Entity}` and live inside the aggregate.
* `DDD.ValueObject` has `new/1` and `equals?/2` and no `update`.
* Entities and aggregates get `created_at` and `updated_at` (`:datetime_usec`) automatically.
  `new/1` sets both, `update/2` and every `defop` bump `updated_at`, `validate/1` does not,
  and `update/2` ignores attempts to set them. Value objects are immutable and have none.

### Identity

Every entity and aggregate has an identity, made of one or more fields, one `identity` each:

```elixir
identity :id, :uuid                 # the usual case

identity :tenant_id, :uuid          # or several: the same SKU in every tenant
identity :sku, :string
```

* `Order.identity(order)` returns it as a string: the value itself for one field, the values
  joined with `:` for several (`"6f1f...:A-100"`). A `:` or `\` inside a part is escaped with a
  `\`, so two different entities can never share a string. `DDD.Identity.decode/1` splits it back.
* `Order.build_identity(tenant_id: t, sku: "A-100")` makes the same string without an entity, and
  `Order.identity_fields()` lists the part names.
* Every part is required, and none can change: `update/2` ignores them and a `defop` that changes
  one returns `:identity_changed`. A part of a composite identity must be a string, uuid, integer,
  atom, date or enum field.
* **Ids.** Only a lone `identity :id, :uuid` is generated by `new/1`, as a UUIDv7 (time-ordered, so
  indexes stay compact), and only when you leave it out. Every other identity is passed in.
  `DDD.Identity` makes ids by hand: `generate/0` (v7), `uuid7/0`, `uuid4/0`, `uuid1/0`,
  `uuid3/2`, `uuid5/2`.
* **Storage.** One field is the table's primary key in its own type (`uuid`). A composite
  identity is stored whole in a `varchar` primary key column named `identity`, next to normal
  not-null columns for each part. `find_by_id/1`, the outbox `aggregate_id` of an event, and a
  `{:ref, Aggregate}` to a composite aggregate all use the identity string.
* Changing an existing aggregate's identity is destructive: `mix vic.gen.migration` refuses
  without `--allow-destructive`, and then writes a migration with a `TODO` to backfill the new key
  for existing rows. It never drops the old key.

### Field types

Every field has a type, and a value of the wrong type is a violation with the code
`:invalid_type` (`nil` is accepted; use `required: true` to forbid it). A misspelled type fails at
compile time.

| type | value | column |
|---|---|---|
| `:string`, `:text` | binary | `varchar`, `text` |
| `:integer`, `:float`, `:boolean` | number, boolean | `bigint`, `float`, `boolean` |
| `:decimal` | `Decimal` | `numeric` |
| `:atom` | atom | `varchar` |
| `:uuid` | UUID string | `uuid` |
| `:date`, `:time`, `:naive_datetime`, `:datetime`, `:datetime_usec` | `Date`, `Time`, `NaiveDateTime`, `DateTime` | `date`, `time(6)`, `timestamp(6)`, `timestamp(0)`, `timestamp(6)` |
| `:binary` | binary | `bytea` |
| `:map`, `:json` | map, or map or list | `jsonb` |
| `{:enum, [:open, :done]}` | one of the atoms | `varchar` |
| `{:array, type}` | list of `type` | Postgres array, e.g. `varchar[]` |
| `{:map, type}` | map with string keys, values of `type` | `jsonb` |
| `{:ref, Aggregate}` | the id of another aggregate | the type of its identity |
| `{:one, Module}`, `{:list, Module}` | nested entities or value objects (a list is one JSON array) | `jsonb` |
| `:money` | `DDD.Money` (`{:one, DDD.Money}`) | `jsonb` |

    field :status, {:enum, [:open, :done]}, default: :open
    field :tags, {:array, :string}, default: []
    field :price, :money
    field :ship_to, {:one, Address}
    field :customer_id, {:ref, Customer}

`DDD.Money` is a value object with a `Decimal` amount and a 3-letter currency. `Money.add/2`,
`subtract/2` and `compare/2` return a business error (`:currency_mismatch`) for two currencies;
there is no silent conversion. A reference is a plain id, so aggregates stay separate; it is
checked against the identity type of the other aggregate. Arrays of arrays are not supported.
`DDD.Type` is the one place that knows what a type means: checking, Postgres, and JSON.

### Domain events

```elixir
defmodule MyApp.Events.ItemAdded do
  use DDD.DomainEvent

  domain_event do
    field :item_id, :string
    field :title, :string
  end
end
```

Every event has `event_id`, `occurred_at`, `created_at` and a link to the aggregate it came
from: `aggregate_type` (the module name as a string) and `aggregate_id`. `emit_event/2` fills
the link in, so events never carry the aggregate's id by hand. The outbox stores the same
link in its `aggregate_type` / `aggregate_id` columns, and the poller restores it.

### Specifications

A specification is a named, reusable, composable business rule. It is a pure function of the entity.

```elixir
defmodule MyApp.Specs.MaxOpenItems do
  use DDD.Specification, field: :items

  def check(%{items: items}, opts) do
    max = Keyword.fetch!(opts, :max)

    if Enum.count(items, &(&1.status == :open)) <= max,
      do: :ok,
      else: {:error, :too_many_open_items, "at most #{max} open items", %{max: max}}
  end
end

# attach it to an entity or aggregate:
invariant MyApp.Specs.MaxOpenItems, max: 10

# use it on its own, or compose it:
MyApp.Specs.MaxOpenItems.satisfied_by?(list, max: 10)
DDD.Specification.evaluate(DDD.Specification.all_of([A, {B, max: 3}]), entity)
```

**Value specs** check one field and are bound to it when attached, so the link is explicit and
one spec serves any field:

```elixir
defmodule MyApp.Specs.ValidEmail do
  use DDD.Specification, scope: :value

  def check(email, _opts) when is_binary(email) do
    if String.contains?(email, "@"), do: :ok, else: {:error, :invalid_email, "must be an email"}
  end
end

invariant MyApp.Specs.ValidEmail, on: :email
invariant MyApp.Specs.ValidEmail, on: :billing_email
```

`check/2` receives the value (never `nil`: absence is `required: true`'s job) and a failure is
reported under the `on:` field. Forgetting `on:` or naming a field the entity doesn't have is a
compile error, so a rename can't leave a spec silently checking nothing. A spec that needs
several fields (`use DDD.Specification, field: :items`, `check(entity, opts)`) is an entity spec
and takes no `on:`.

`all_of/1`, `any_of/1` and `not_spec/1` build composite specs. Specs run only after field rules
pass, so they can assume required fields are present. Rules that need the database (for
example "the owner exists") belong in the command handler.

### Business operations: `defop`

`defop` marks a function as a business operation. The body returns the new struct, or
`{:error, reason}`. The framework then validates and seals the result.

**State the business rules explicitly, as named preconditions**, not by pattern-matching the
entity in the function head:

```elixir
defop complete(item), requires: MyApp.Specs.ItemNotCompleted do
  %{item | status: :done}
end

defop rename(item, %MyApp.Title{} = title), requires: MyApp.Specs.ItemEditable do
  %{item | title: title}
end

# Several rules, some with options; all of them are checked and all failures reported:
defop ship(order), requires: [MyApp.Specs.OrderIsPaid, {MyApp.Specs.InStock, warehouse: :main}] do
  %{order | status: :shipped}
end
```

`requires:` takes specifications (see above), checked against the entity (the first argument)
before the body runs. A broken rule returns a business error with `code: :precondition_failed`,
the rule's own message, and one violation per broken rule carrying its code:
`DDD.Error.has_code?(error, :already_completed)`. Every broken rule is reported at once.
Invariants are the mirror image: they check the state *after* an operation.

The operation's *other* arguments reach each spec as `opts[:args]`, so a rule can depend on
them. That is how the example's `TodoList.complete_item(list, item_id)` states its prerequisites
where a reader looks:

```elixir
defop complete_item(list, item_id),
  requires: [Specs.ItemExists, {Specs.ItemSatisfies, spec: Specs.ItemNotCompleted}] do
  ...
end

# ItemExists reads the id from opts[:args]:
def check(%{items: items}, opts) do
  [item_id | _] = Keyword.fetch!(opts, :args)
  if Enum.any?(items, &(&1.id == item_id)), do: :ok, else: {:error, :item_not_found, "..."}
end
```

`ItemSatisfies` lifts a rule about one item (written once, on the item) to the list that holds
it. Specs are evaluated against the first argument only, so a rule about an item can't be
attached to the list directly: the list has no `status`, and the spec would pass every call.

Patterns in the head are for the *shape of the arguments* (`%Date{}`, `%Title{}`), not for
business rules.

* Arguments that match no clause: `{:error, %DDD.Error{code: :invalid_operation}}`.
* Events emitted with `emit_event/2` are dropped when the operation is rejected or the result
  is invalid.
* An operation with several clauses is guarded by the preconditions of all of them.

### Errors

Every failure is `{:error, %DDD.Error{}}` with `kind`, `entity`, `entity_id`, `operation`, `code`,
`message`, `details`, `violations` and `context`. `entity` is the kind of entity (the module) and
`entity_id` the identity of the instance it happened to (`Entity.identity/1`, so
`"tenant:sku"` for a composite identity), or `nil` when there is none: a `new` call missing its
identity, or an error that isn't about an instance. Validation, preconditions, unsealed structs,
identity changes, a lost update and a failed save all carry it. An MCP client sees `entity` (the
short name) and `entity_id` in a business error. The `kind` is `:business` (the domain said no;
retrying gives the same answer) or `:infrastructure` (the system failed; retrying may succeed).
Running a command adds `command` to `context`. `DDD.Error.has_code?/2` and
`DDD.Error.to_map/1` (a `%{field => [messages]}` map) help callers.

### Sealing

Every struct has a required `__sealed__` key, so `%Todo{...}` literals do not compile by
accident. The seal is a fingerprint of the data, set only after validation. Repositories and
`defop` reject structs whose seal does not match (`code: :unsealed`). `defop` checks every framework
struct among its arguments, not just the entity, so `add_item(list, item)` refuses a forged `item`.

An aggregate's **pending events** are sealed too. `emit_event/2` and `pop_events/1` are the only
ways to change them and they keep the seal, so replacing the list by hand makes the aggregate
unsealed and `defop`, `update/2` and `save/1` refuse it. `validate/1` also refuses an unsealed
aggregate that carries events, rather than sealing events it cannot vouch for.

### Repositories

```elixir
defmodule MyApp.TodoListRepository do          # domain layer: the port
  use DDD.Repository
  repo MyApp.TodoList do
    find_by :owner_id
  end
end

defmodule MyApp.Infrastructure.TodoListRepository do   # infrastructure: generated adapter
  use DDD.Repository.Ecto, port: MyApp.TodoListRepository, repo: MyApp.Repo, table: "todo_lists"
end
```

The whole aggregate is one row. Nested entities are stored as `jsonb` and rebuilt into sealed
structs on load; keys missing from old rows take the field default. `save/1` writes the
aggregate and its domain events (the outbox) in one transaction.
`DDD.InMemoryRepository` is available for tests.

### Optimistic locking

Every aggregate has a `version`, which starts at 0 and is advanced by the repository on every
save, never by the domain (`new/1` and `update/2` ignore it; a `version` field you declare
yourself is left alone). `save/1` writes `UPDATE ... WHERE id = ? AND version = ?`, so two
requests that loaded the same aggregate cannot both win: the second one gets

```elixir
{:error, %DDD.Error{kind: :infrastructure, code: :stale_aggregate,
                    details: %{id: ..., expected_version: 3, actual_version: 4}}}
```

and nothing is written, events included. It is an *infrastructure* error: nothing about the
request is wrong, and running the command again on fresh data may well succeed. The outbox
retries a handler that fails this way by itself; for a command say how often to re-run it:

```elixir
use DDD.Command, retry_on_conflict: 3      # re-runs execute/1, up to 3 more times
```

A save is also a conflict when the row was deleted since you loaded it, or when a *new*
aggregate (version 0) uses an id that already exists. A command called inside an open
transaction is not retried: that transaction is already doomed. `mix vic.gen.migration` adds the
column (`null: false, default: 0`, so existing rows start at 0). Each conflict is a
`[:ddd, :repository, :conflict]` telemetry event.

### Listing: filters, pages and cursors

An Ecto adapter (and a projection) also has `list/1`, `count/1`, `page/1` and `slice/1`:

```elixir
TodoListRepository.list(filter: [owner_id: id, status: {:in, [:open, :late]}], order: :title)

{:ok, %DDD.Page{entries: lists, page: 2, total_entries: 57, total_pages: 3}} =
  TodoListRepository.page(filter: [owner_id: id], order: [desc: :created_at], page: 2, page_size: 20)

# keyset pagination: no OFFSET, no totals, stable while rows come and go
{:ok, %DDD.Slice{entries: lists, next_cursor: cursor}} = Repo.slice(order: :title, limit: 20)
{:ok, next} = Repo.slice(order: :title, limit: 20, after: cursor)
```

The filter language (`DDD.Filter`) has equality, `:gt :gte :lt :lte :neq :in :not_in :like
:ilike`, `nil` for `NULL`, and `{:and, _}`, `{:or, _}`, `{:not, _}`. Values are bound parameters.
The identity is always the last sort key, so every order is total and pages never overlap. A bad
field, operator, order, page number or cursor is a *business* error (`:invalid_filter`,
`:invalid_order`, `:invalid_page`, `:invalid_cursor`), because these usually arrive straight from
a request.

**Specifications can search.** A spec is a pure function of an entity, so the database can't run
it; a spec that also defines `to_filter/1` (the same rule, written as a filter) can be given to
the repository, alone or composed with `all_of`, `any_of` and `not_spec`:

```elixir
def to_filter(_opts), do: [status: :open, due: {:lt, Date.utc_today()}]

TodoListRepository.list(spec: DDD.Specification.all_of([Overdue, {OwnedBy, owner: id}]))
```

A spec without `to_filter/1` raises an `ArgumentError` there: it can only be checked in memory.
Keep the two in step; a test that runs both over the same rows is cheap.

### Commands

A command is the input of one use case and carries its own handler, `execute/1`. The handler
loads aggregates through repositories, calls domain operations and saves. It holds no business
rules.

```elixir
defmodule MyApp.Commands.AddItem do
  use DDD.Command

  command do
    field :list_id, :string, required: true
    field :title, :string, required: true
  end

  @impl DDD.Command
  def execute(%__MODULE__{list_id: list_id, title: title}) do
    with {:ok, list} <- load_list(list_id),
         {:ok, item} <- MyApp.TodoItem.new(title: title),
         {:ok, list} <- MyApp.TodoList.add_item(list, item) do
      MyApp.Infrastructure.TodoListRepository.save(list)
    end
  end
end

MyApp.Commands.AddItem.call(%{list_id: id, title: "Buy milk"})   # builds, validates, executes
```

* `new/1` builds and validates the command (`required: true` fields).
* `call/1` takes a struct or plain attrs. Every error comes back as a `DDD.Error` with
  `context: %{command: MyApp.Commands.AddItem}`. `call!/1` raises instead.

**Transactions.** `execute/1` runs in its own database transaction by default. `{:ok, _}`
commits; `{:error, _}` rolls back everything the handler did, including every aggregate it
saved and their outbox events; an exception rolls back and propagates. Repository
transactions inside the handler join it, so a command that saves two aggregates is atomic.
Validation in `new/1` runs before the transaction starts.

```elixir
use DDD.Command                        # default: transaction on the configured repo
use DDD.Command, repo: MyApp.Repo      # another repo
use DDD.Command, transaction: false    # no transaction (e.g. in-memory repositories)
```

### Queries

A `DDD.Query` is the read counterpart of a command: fields, `new/1`, `call/1`, `execute/1`, but it
never saves an aggregate or emits an event. Its `execute/1` runs in a **read-only Postgres
transaction**, so "this cannot change data" is enforced by the database, and it sees one
consistent snapshot. `use DDD.Query, transaction: false` opts out; a query called inside an open
transaction joins it.

```elixir
defmodule MyApp.Queries.OpenItems do
  use DDD.Query

  query do
    description "The items of a list that are not done yet"
    field :list_id, :uuid, required: true, description: "The list to read"
  end

  @impl DDD.Query
  def execute(%__MODULE__{list_id: id}), do: ...    # {:ok, data} | {:error, reason}
end
```

Command and query fields are `DDD.Type`s, checked on `new/1` (`:invalid_type`). Every module
that can be described takes `description "..."`: commands, queries, entities, aggregates and
value objects; `field ..., description: "..."` describes a field and
`defop name(...), description: "..."` an operation. Descriptions are plain metadata
(`__description__/0`, `__ddd_description__/0`); the MCP server reads them.

### MCP server

The framework can serve the application over the [Model Context Protocol](https://modelcontextprotocol.io),
so an AI client such as Claude can call its commands and queries and read its aggregates. The
protocol core is `DDD.MCP` (JSON-RPC 2.0, no extra dependency); the first transport is stdio.

```elixir
defmodule MyApp.Interface.MCP do
  use DDD.MCP.Server,
    instructions: "Manage todo lists.",
    commands: [MyApp.Commands.CreateList, {MyApp.Commands.RenameItem, name: "rename_todo"}],
    queries: [MyApp.Queries.OpenItems],
    repos: [MyApp.TodoList.Repository],
    read_only: false,
    authorize: &MyApp.MCPPolicy.authorize/2
end
```

```
mix compile && mix vic.mcp MyApp.Interface.MCP            # serve on stdin/stdout
mix vic.mcp MyApp.Interface.MCP --read-only               # queries and resources only
claude mcp add todo -- mix vic.mcp MyApp.Interface.MCP
```

* **Nothing is exposed unless it is listed**, and the commands and entities carry no MCP code.
  What you list is the level of access: only `queries:` and `repos:` is a read-only server.
* **Tools.** Each command or query is a tool named after the module (`AddItem` is `add_item`,
  overridable per entry; two with one name stop the server at startup). Its input schema is built
  from the fields: the `DDD.Type` (enums become `enum`, `:uuid` a UUID string, nested value
  objects objects), `required`, `default` and the descriptions. Queries carry `readOnlyHint: true`.
  A module with no `description` cannot be exposed. Arguments are converted from JSON through
  `DDD.Type`; nested entities and value objects are built with their own `new/1`, so their rules
  run, and atoms are never created from input.
* **Resources.** An exposed aggregate (list its repository port, which must define `impl/0`) is
  read-only: `todo_list://<identity>` reads one and `todo_list://by/owner_id/<value>` runs a
  `find_by` the port declares, at most 100 results (`truncated` says when it was cut).
  `resources/list` is empty on purpose: nothing hands a client a whole table. Every field of the
  aggregate is shown; to keep data back, don't expose the aggregate and return a curated map from
  a query.
* **Errors.** A business error (validation, not found, a precondition) is returned with its code,
  message and violations so the client can correct itself. An infrastructure error is a generic
  "the operation failed" and its details only go to the log. A malformed call gets a JSON-RPC
  error saying what was wrong.
* **Access.** `read_only: true` (or `--read-only`) refuses every command. `authorize:` is called
  with `(tool_name, arguments)` before each tool call, and with `("resource:<name>", %{"uri" => uri})`
  before each resource read; return `:ok` or `{:error, reason}`.
* **Stdio hygiene.** Standard output carries only protocol messages. The task moves the logger to
  standard error and turns the SQL log and the outbox poller off. Run `mix compile` first, because
  Mix prints its compile output on standard output when sources changed.

## Migrations

```bash
mix vic.gen.outbox_migration                 # the domain_events outbox table
mix vic.gen.migration MyApp.TodoList         # first run: create table
mix vic.gen.migration MyApp.TodoList         # later runs: only the difference
```

The generator keeps a snapshot of each aggregate in `priv/ddd_snapshots/` and writes the
difference as a new migration. It never overwrites earlier migrations.

* Removing a column or changing its type loses data, so it is refused unless you pass
  `--allow-destructive`. Destructive operations are marked in the generated file.
* Renames must be explicit, otherwise they are a remove plus an add:
  `--rename old:new`, or `field :name, :string, renamed_from: :old_name`. (The example app moved
  from `inserted_at` to `created_at` this way, with no data loss.)
* Edits inside a nested entity do not change columns. Old rows keep the old shape, and
  defaults fill the missing keys on load. Reshaping existing data needs a hand-written migration.
* Nested lists are stored as one `jsonb` array.

Check for drift between aggregates and the real tables in a test:
`DDD.Migration.drift(MyApp.TodoList, "todo_lists", MyApp.Repo)`.

## Unit of work

A command runs inside a **unit of work**. Inside it the repositories remember what the command
loaded and saved, and write the changes **once, when `execute/1` returns `{:ok, _}`**, just
before the command's transaction commits.

```elixir
def execute(%{order_id: id}) do
  with {:ok, order} <- Orders.find_by_id(id),      # loaded: one query
       {:ok, order} <- Order.ship(order),
       {:ok, order} <- Orders.save(order),         # recorded, not written yet
       {:ok, again} <- Orders.find_by_id(id) do    # no query: the same order, at its new version
    {:ok, again}
  end
end                                                # written here, then the transaction commits
```

* `find_by_id` loads an aggregate once. Asking again returns it without a query, including one
  you have just saved (at the version it will have) and `{:error, :not_found}` for one you have
  deleted.
* `save` and `delete` return at once. `save` returns the aggregate with the version it will have
  once written. Saving the same aggregate twice writes it once, with all its events.
* Only what changed is written. An aggregate that was loaded and left as it was costs nothing.
* If a write fails, the command returns that error and the transaction rolls back. A version
  conflict is still `:stale_aggregate`, so `retry_on_conflict` works as before, but it now shows
  at the end of the command, not at the `save` call. Everything that lost is reported at once:
  `error.details` has the usual `id`, `expected_version` and `actual_version` of the first one,
  and `conflicts`, a list of all of them (`actual_version` is `nil` for a row that is gone).
* A command called from inside another command joins its unit of work; the outermost one writes.
  A transactional event handler gets one per delivery. Outside both, nothing changes: `save`
  writes at once.
* `use DDD.Command, unit_of_work: false` runs a command without one. `DDD.UnitOfWork.run/1`
  opens one around any other code.

### Deadlocks and `flush_order: :sorted`

Two commands that change the same rows can wait for each other, and the database then aborts
one of them (Postgres `deadlock_detected`, MySQL error 1213). That transaction is rolled back and
the command returns an infrastructure error with code `:deadlock_detected`, which
`retry_on_conflict` retries just like `:stale_aggregate`, with the same random wait. A command
without `retry_on_conflict` gets the error and decides for itself; nothing is retried behind its
back. Only the dialect's idea of "worth retrying" is used: a deadlock, or a serialization failure
on Postgres. Any other database error is still raised.

By default the writes go in the order they were recorded. If two commands that change the same
rows in different orders deadlock often, ask for an order they all share:

```elixir
use DDD.Command, retry_on_conflict: 3, flush_order: :sorted
```

The tables are then written in name order and the rows of each in key order, and the rows about
to change are locked in key order first (one more statement per repository). Commands that all
use `:sorted` cannot deadlock each other over the rows they write. If a command joins another
unit of work and asks for `:sorted`, the whole of it is sorted.

### Loading up front with `loads:`

A command that works on many aggregates would read them one `find_by_id` at a time. Declare
where their ids are and they are read together, before `execute/1`:

```elixir
defmodule MyApp.Commands.ShipOrders do
  use DDD.Command

  command do
    field :order_ids, {:array, :string}, required: true, loads: MyApp.Order
    field :carrier_id, {:ref, MyApp.Carrier}, required: true, loads: true
  end

  @impl DDD.Command
  def execute(%{order_ids: ids, carrier_id: carrier_id}) do
    {:ok, carrier} = Carriers.find_by_id(carrier_id)     # already loaded: no query

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, shipped} ->
      with {:ok, order} <- Orders.find_by_id(id),         # already loaded: no query
           {:ok, order} <- Order.ship(order, carrier),
           {:ok, order} <- Orders.save(order) do
        {:cont, {:ok, [order | shipped]}}
      else
        error -> {:halt, error}
      end
    end)
  end
end
```

That command, for 20 orders, runs 5 statements: one read of the orders, one of the carrier, one
`UPDATE` for all 20 orders and one `INSERT` of their events, inside the transaction. Without
`loads:` it is the same code with 20 more reads.

`loads:` names the aggregate, and where it is stored is configured once:

```elixir
config :vicander, :repositories, [
  {MyApp.Order, MyApp.OrderRepository},     # an adapter, or a port with impl/0
  {MyApp.Carrier, MyApp.CarrierRepository}
]
```

On a `{:ref, Aggregate}` field the aggregate is already named, so `loads: true` is enough. A
repository, a port or an adapter can be named directly instead (`loads: MyApp.OrderRepository`).

The aggregates go into the unit of work, not into a variable: `execute/1` keeps calling
`find_by_id`. An id that does not exist fails the command before it starts, with a business
error (`code: :not_found`, `entity`, the first missing id as `entity_id`, and the `field` and all
`missing_ids` in `details`), so nothing has been done by then. `nil` and `[]` load nothing. Ids
that only turn up while the command runs (`order.customer_id`) are not declared; they load when
asked for.

### What is written, and how

On Postgres the changes of one repository are written in a handful of statements, however many
aggregates there are: one `INSERT` for the new ones, one `UPDATE ... FROM (VALUES ...)` for the
changed ones, one `DELETE` for the removed ones, and one `INSERT` of all their events into the
outbox. Each update and delete is guarded by the version the aggregate was loaded at, so a row
that someone else changed is not touched and is reported as a conflict.

An aggregate is written when a field differs from what was loaded. One that was loaded and left
as it was costs nothing. One that only emitted events (`Order.emit_event/2` called directly,
with no field changed) is not rewritten, but its version is checked, so the event is not
recorded for a state that is out of date. Note that every operation (`defop`) bumps `updated_at`,
so an aggregate changed by an operation counts as changed.

A database without batched writes is written one aggregate at a time; the rules above hold.
`[:ddd, :unit_of_work, :flush]` is a telemetry span, emitted once per flush that wrote something.
Its stop event measures `inserted`, `updated`, `checked`, `deleted`, `events`, `statements`, and,
for the whole unit of work, `loaded` (aggregates read from the database) and `hits` (`find_by_id`
calls answered from memory).

### Reads that are not by id

There is no `flush`. The database does not have your unwritten changes, so a query by anything
other than the id (`find_by_*`, `list`, `page`, `slice`, `count`) **raises
`DDD.UnitOfWork.PendingChangesError` once the command has saved or deleted something**, rather
than return an answer that is quietly wrong.

```elixir
with {:ok, order} <- Orders.find_by_id(id),
     [] <- Orders.find_by_reference(order.reference),   # fine: nothing is pending yet
     {:ok, order} <- Orders.save(order),
     do: Orders.find_by_reference(order.reference)      # raises: the save is not written yet
```

Run the query before the first `save`, or split the work into two commands (the second can be
started by an event). Reads by id are always fine.

**What cannot be detected:** code that goes around the repositories (`Repo.query!`, `Repo.all`
on your own schema) reads the database and does not see the unwritten changes.

### Which commands fail, and how to split them

A command may save and delete as many aggregates as it likes; that is what the unit of work is
for. Only a **query that is not by id, after a save**, is a problem.

The guard looks at the whole unit of work, not at one repository: once **any** aggregate in it
has been saved (new or changed) or deleted, **every** later query that is not by id raises
`PendingChangesError`, even on another repository and even if the query could not have touched
what was saved. The command fails, its transaction rolls back, and `retry_on_conflict` does not
retry it: the error is a bug in the command, not a conflict. This is deliberate, so a command
that works on a test database cannot start giving quietly wrong answers on a busy one.

Note that a command called by another command shares its unit of work, so the rule applies to a
**chain**: a step's saves count for every step after it.

| What the command does, in order                                  | Result   |
|------------------------------------------------------------------|----------|
| `save` A, `save` B, `save` C (any repositories, any number)      | works: saves never raise; all are written together at the end |
| `save` the same aggregate twice                                  | works: written once, with all its events |
| `find_by_id`, `save`, `find_by_id` (same or another aggregate)   | works: by id, answered from what was saved |
| `find_by_*` / `list` / `count`, then `save`                      | works: nothing is pending yet |
| `find_by_*`, `save`, then `find_by_*` again                      | **raises** |
| `save` A, then `list` on another repository                      | **raises** |
| `delete`, then `count`                                           | **raises** |
| `save` an aggregate that did not change, then query              | **raises**: the save is recorded even if nothing is written. Do not save what you did not change |
| command 1 saves, command 2 (chained inside) queries              | **raises** |
| command 1 saves and returns, command 2 queries (two calls)       | works: command 1 committed |
| `Repo.all` / `Repo.query!` after a save                           | no error, **stale answer** |

(The in-memory repository, `DDD.InMemoryRepository`, is not yet guarded the same way: a command
that saves and then queries passes against it and raises against Ecto. Test such a command
against the database repository.)

#### Rewriting a command so it works

In order of preference:

1. **Query first, then change.** Almost every failing command only needs the answer *before* it
   changes anything. Move the `find_by_*`, `list` or `count` to the top of `execute/1`, or into
   the `loads:` of the command. This is free and keeps one transaction.

   ```elixir
   # raises: the save comes before the query
   with {:ok, list} <- Lists.find_by_id(id),
        {:ok, list} <- Lists.save(TodoList.add_item(list, title)),
        {:ok, lists} <- Lists.find_by_owner_id(list.owner_id), do: ...

   # works: ask first
   with {:ok, list} <- Lists.find_by_id(id),
        {:ok, lists} <- Lists.find_by_owner_id(list.owner_id),
        {:ok, list} <- Lists.save(TodoList.add_item(list, title)), do: ...
   ```

2. **Use ids instead of queries.** If the later step only needs something you have just
   created, pass the id along and read it with `find_by_id`; that is always answered from the
   unit of work. This is why chaining `RegisterUser`, `CreateList` and `AddItem` works.
3. **Split into two commands connected by an event.** When the second step must see the first
   one's committed result (a count, a list, a search), the first command emits an event and a
   handler calls the second command once the first has committed. Each step is its own
   transaction, retried on its own, and the second runs only if the first succeeded. You give
   up all-or-nothing across the two; the outbox delivers at least once, so make the second
   command safe to run twice.
4. **Run two commands one after the other**, from whoever drives them (an HTTP handler, a job).
   The first commits, so the second sees its work. Use this when the caller needs both results
   at once and can accept that the first may succeed and the second fail.
5. **Compute it in memory.** If the "query" is really "how many items does this list have now",
   read the aggregate (by id) and look at its fields; the value object you just changed already
   has the answer.

#### A worked example: discounts from money spent

A calculation can be as complex as you like and still be one command in one transaction, as
long as it follows one shape: **read everything, decide, then write**. Take a nightly job that
gives each customer a discount tier from what they spent in the last 90 days. Computing
"what they spent" is a query over orders (not by id), so it must come before the first save.

```elixir
defmodule MyApp.Commands.ApplyDiscounts do
  use DDD.Command

  command do
    # One page of customers; the job starts one command per page.
    field :user_ids, {:array, :string}, required: true, loads: MyApp.User
    field :since, :datetime, required: true
  end

  @impl DDD.Command
  def execute(%{user_ids: ids, since: since}) do
    # 1. READ. Queries are fine: nothing has been saved yet.
    spent = Orders.total_spent_by_user(ids, since)        # %{user_id => amount}, one query

    # 2. DECIDE. Plain Elixir, any amount of logic; no database involved.
    #    (the customers were loaded by `loads:`, so `find_by_id` costs no query)
    changes =
      Enum.flat_map(ids, fn id ->
        {:ok, user} = Users.find_by_id(id)
        tier = tier_for(Map.get(spent, id, 0))

        if tier == user.tier do
          []                                   # unchanged: not saved, so not written
        else
          {:ok, changed} = User.change_tier(user, tier)
          [changed]
        end
      end)

    # 3. WRITE. As many saves as you like: one batch, one transaction, at the end.
    Enum.reduce_while(changes, {:ok, []}, fn changed, {:ok, saved} ->
      case Users.save(changed) do
        {:ok, user} -> {:cont, {:ok, [user | saved]}}
        error -> {:halt, error}
      end
    end)
  end
end
```

(`total_spent_by_user` is a query you define on the orders port; `tier_for` and
`User.change_tier/2` are your own.) If one customer was changed by someone else meanwhile, the
whole page is reported as `:stale_aggregate` and, with `retry_on_conflict`, run again on fresh
data.

**When the calculation needs the database after it has written.** Say that after changing the
tiers you must rank all customers by what they now pay, and the ranking is a query that depends
on the new tiers. That query would be after a save, so it raises. Three ways out, in order of
preference:

1. **Make the query not depend on the write.** Almost always the ranking can be computed from
   data you already have: `spent` and the tiers you just decided are all in memory. Compute the
   ranking in step 2, before saving. The command stays batched and in one transaction.
2. **Split in two, connected by an event.** The first command applies the tiers and emits
   `DiscountsApplied`; a handler runs a second command that builds the ranking from the
   committed data. Each part has its own transaction and retry. You give up all-or-nothing
   across the two parts, and the second command must be safe to run twice.
3. **Turn the unit of work off for this one command: `use DDD.Command, unit_of_work: false`.**
   It is still **one transaction around the whole command**, but every `save` is now written
   at once inside it, so a later query sees it (this is how commands worked before the unit of
   work existed). It costs the batching (one statement per save) and `loads:` (the two cannot
   be combined; the compiler says so). Use it for a rare, heavy, sequential command, not as the
   default.

**Two things to watch with this kind of command:**

* **The sums are not version-checked.** The customers are (a concurrent change to one fails the
  command or retries it), but the orders you summed are plain rows: an order placed while the
  command runs is counted or not depending on timing. If the result must be exact at one moment,
  read the totals from a consistent source (a snapshot, a closed period such as "orders before
  midnight") instead of "orders so far".
* **Size.** A command is one transaction, and a transaction that touches every customer holds a
  lot of locks for a long time. Split the work into pages (one command per page of ids, started
  by a scheduler) so each page is a short, all-or-nothing unit of its own.

#### Best practices

* **One command, one aggregate-sized decision.** A command should change what must be consistent
  together, no more. Things that may become consistent a moment later belong in a second command
  triggered by an event ("eventual consistency between aggregates").
* **Declare what you load.** `loads:` fetches every id the command was given in one query
  before `execute/1`, so there is nothing to query between changes.
* **Put queries in the first half of `execute/1`.** A good shape is: read everything, decide,
  change, save. If you find yourself wanting to read again after saving, that read is a second
  command.
* **Chain for ids, event for queries.** Commands that need each other's *ids* can be chained in
  one transaction; commands that need each other's *query results* are connected by an event.
* **Do not work around the guard.** Reading with raw Ecto after a save sees stale data and no
  error. If it feels necessary, the command is doing two jobs: split it.
* **Make second steps idempotent.** Whatever is started by an event can run more than once;
  give it a natural key or check whether the work is already done.
* **Test the whole path against the database repository.** A unit test with the in-memory
  repository does not yet raise for a save followed by a query.

#### Why it works this way

The restriction is the price of a goal, and it was chosen on purpose.

**The goal.** A command that changes twenty aggregates used to cost about 82 queries (a read, a
version read, an update and an events insert for each, plus begin and commit). The unit of work
loads what it needs up front and writes everything that changed in a handful of statements: 5
queries instead of 82 in the same scenario, and far fewer contended retries, because a
transaction holds its row locks for a shorter time. That is only possible if `save` does **not**
write: it records the change, and the write happens once, when the command succeeds.

**The consequence.** While changes are unwritten, the database does not have them. Anything that
asks the database a question other than "give me row X" can answer without them. By id the
framework can still answer correctly, because it holds the aggregate in memory (the identity map).
A query by another field (`find_by_email`, `list`, `count`) cannot be answered from memory: that
would mean re-implementing the database's query engine over the aggregates held in memory.

**What else was considered, and why it was not chosen:**

| Option | What it does | Why not |
|---|---|---|
| Write on every `save` (the old behaviour) | Queries always see the latest state | No batching: 82 queries instead of 5; locks held longer |
| Automatic flush before a query (what Hibernate does) | Writes pending changes just before a non-id query, then runs it | The writes are no longer one batch. Worse, **where** the writes happen now depends on what the code reads, so adding a query in one place changes the statements, the lock order and the failure point somewhere else. Hard to see, hard to test |
| A public `flush()` | The command decides when to write | Every command must remember to call it, and a wrong flush point is a silent performance or consistency bug. It also invites one big command with several flushes, which is the thing a unit of work is meant to prevent |
| Answer the query from memory too | Queries see unwritten changes | Needs a query engine over aggregates in memory; any difference from the database's answer is a quiet bug |
| **Raise on a query after a save (chosen)** | The command fails, loudly, the first time it runs | The command has to be arranged as read, decide, write, or split in two |

Raising was preferred to every quiet alternative for two reasons. A wrong answer from a query
(a count that misses the item you just added) is far worse than an error, because nothing tells
you. And an error that happens on the first run, in a test, is cheap to fix, whereas a flush that
changes behaviour under load is not.

**It also pushes commands towards a good shape.** A command that must save and then ask the
database something about the result is doing two things: the second depends on the first being
committed. Making that visible, and asking for it to be written as two commands connected by an
event, matches how the rest of the framework works (small commands, events between aggregates).
The cost is real, though: a chain that an in-memory implementation would run happily has to be
rearranged, as the example application's `CompleteItem` and `RecordProgress` were.

**What is not decided.** If this proves too strict, an opt-in automatic flush per command
(`flush_before_queries: true`) can be added without changing anything for commands that do not use
it. It would give up the single batch for that command only. It has not been built.

The example application shows both sides: `OnboardUser` is a chain that works because every
step reads by id, and `CompleteItem` followed by `RecordProgress` in one command is the chain that
raises, connected instead through the `ItemCompleted` event (see its README, "Chaining commands").

### With `transaction: false`

A command without a transaction still has a unit of work, so its saves are written only if it
succeeds: a command that fails after its first `save` writes nothing. (Before, that first save
stayed.) The flush itself is atomic: it opens a short transaction of its own, so a conflict
writes none of it. Use `unit_of_work: false` as well for the old behaviour, where every `save`
is written, and kept, at once.

## Databases

The dialect is picked from the repo's Ecto adapter (`config :vicander, :dialect, MyDialect` picks
another). Postgres and MySQL 8 are supported:

| | Postgres | MySQL 8 (`myxql`) |
|---|---|---|
| Aggregates, commands, outbox, poller, dead letters | yes | yes |
| Unit of work, `loads:`, batched writes | yes | yes |
| One `UPDATE` for many aggregates | `UPDATE ... FROM (VALUES ...)` | locking read, then `UPDATE ... JOIN (SELECT ... UNION ALL ...)` |
| Claiming events | `FOR UPDATE SKIP LOCKED` | `FOR UPDATE SKIP LOCKED` |
| Queries are read-only in the database | yes | when the connection is not in a transaction already |
| Array columns (`{:array, type}`) | yes | no: use `:map` or a list of value objects (JSON) |
| Partial indexes of the outbox | yes | no: `mix vic.gen.outbox_migration` leaves them out |

A MySQL batched `UPDATE` first locks the rows it will write, in key order, and reads their
versions; MySQL reports changed rows, not matched ones, so that read is how it knows exactly which
aggregates lost a race. The result is the same as on Postgres: one `:stale_aggregate` listing
every conflict.

The framework's own tests run on both: `mix test` on Postgres, and

```
docker run -d -e MYSQL_ROOT_PASSWORD=mysql -p 3306:3306 mysql:8.0
DB=mysql mix test --only mysql
```

on MySQL (`MYSQL_HOST`, `MYSQL_PORT` and `MYSQL_PASSWORD` point it elsewhere). To support another
database, implement `DDD.Dialect`: the four basic callbacks, and the optional batched ones
(`insert_new/4`, `update_versioned/5`, `delete_versioned/4`) and `retryable?/1`. Without the
batched ones it still works, one aggregate at a time.

## Outbox

Events are written to the `domain_events` table in the same transaction as the aggregate (and
inside the command's transaction), so a state change and its events commit together or not at
all. `DDD.Outbox.Poller` then delivers them to their handlers:

1. **Claim** a batch of due events with a lease and `FOR UPDATE SKIP LOCKED`, so several
   pollers or nodes never take the same event.
2. **Deliver** to every subscribed handler, synchronously. The events of one aggregate are
   delivered one after another, in order; different aggregates run side by side.
3. **Mark published only when every handler succeeded or rejected**, for the whole batch in one
   statement. A system failure is
   retried after an exponential backoff (1s, 2s, 4s ... capped at 5 minutes). After
   `max_retries` retries (default 10, so 11 attempts) the event is dead-lettered: `failed_at`
   is set, `last_error` says why, and it is no longer claimed.

The attempt is counted when the event is claimed, so even an attempt that kills the whole VM
uses one up. If the server stops mid-delivery, the lease expires and the event is delivered
again; handlers that had already succeeded are skipped.

A poll claims 20 events (`batch_size`). When a batch comes back full the poller polls again at
once, and it sleeps `interval_ms` (3 seconds) only when nothing is left, so a backlog drains as
fast as the handlers allow and the interval is just the delay before an event on an idle system
is noticed.

### Sizing the pool

The poller, your handlers and your web requests all draw on the same Ecto pool. Up to
`concurrency` aggregates (default 4) are delivered at once, and each holds a connection while its
handlers run, plus one for the poller's own claim. Keep `concurrency` below the repo's
`:pool_size`, and leave room for requests; the poller logs a warning at start-up when
`concurrency` is not below the pool size. A handler that calls a slow external API holds its
connection for the whole call, so give it `transaction: false` or call the API outside the
database work.

```elixir
{DDD.Supervisor, handlers: [...], poller: [batch_size: 20, concurrency: 4, interval_ms: 3_000]}
```

Commands that lose an optimistic-lock race and use `retry_on_conflict` wait a random 1 to 5 ms
before the first retry, doubling the cap on each further one up to 200 ms, so a hot aggregate
sheds load instead of every loser retrying at the same moment.

### Handlers

```elixir
defmodule MyApp.OnItemCompleted do
  use DDD.EventHandler, events: [MyApp.Events.ItemCompleted]

  @impl DDD.EventHandler
  def handle(%MyApp.Events.ItemCompleted{aggregate_id: list_id}) do
    case MyApp.Commands.RecordProgress.call(%{list_id: list_id}) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}   # business: rejected. infrastructure: retried
    end
  end
end

MyApp.OnItemCompleted.subscribe()
```

What `handle/1` returns decides what happens, using the kind of the error (`DDD.Error.kind`):

| `handle/1` returns | Meaning | Outcome |
|---|---|---|
| `:ok` | handled | delivered |
| `{:error, %DDD.Error{kind: :business}}` or a plain reason like `:not_found` | the handler looked at the event and said no. Deterministic. | **rejected**: recorded in `event_deliveries` (`outcome: "rejected"`), never retried, **not** a dead letter |
| `{:error, %DDD.Error{kind: :infrastructure}}`, an exception, a throw | the system failed | **retried** with backoff; dead-lettered when retries run out |

In both failure cases a transactional handler is rolled back first. A rejection is remembered,
so the handler is not run again for that event.

Errors the framework creates carry the right kind: validation, invalid operations and
unsealed structs are `:business`; a rolled-back command transaction, a failed save and
exceptions are `:infrastructure`. Build your own with `DDD.Error.business/1` and
`DDD.Error.infrastructure/1`. A plain reason is the domain's answer, so it counts as business.

**Each delivery runs in its own transaction by default**, together with a row in
`event_deliveries` that records "this handler processed this event". If the handler fails,
everything rolls back, including that row, and the event is retried. If it succeeds, the handler
is never run again for that event, even if another handler of the same event failed. For
handlers that only write to our database this is effectively exactly-once. Events a handler
produces (by saving aggregates) commit with its work, so chained events are safe too: they only
exist if the handler succeeded.

For an effect a transaction can't undo (sending an email, calling an API), use
`transaction: false`. That handler is delivered at least once and must tolerate a repeat:

```elixir
use DDD.EventHandler, events: [...], transaction: false
use DDD.EventHandler, events: [...], repo: MyApp.Repo
```

Plain modules with `handle/1` work as well and are delivered like `transaction: false`.

### Pruning

`domain_events` and `event_deliveries` grow with every event. Delete the old ones when you
don't need them any more:

```bash
mix vic.outbox.prune --older-than-days 30
```

or on a timer, with `{DDD.Supervisor, retention: [older_than_days: 30]}`, or from your own
scheduler with `DDD.Outbox.Retention.prune(MyApp.Repo, older_than_days: 30)`. Only published
events and resolved dead letters are deleted; waiting events, events being retried and unresolved
dead letters are kept. Nothing is pruned unless you ask: there is no default age. A projection
is rebuilt by replaying the events that are left (see *Projections*), so prune after the
history you want to be able to rebuild from, or archive the table first.

### Retry configuration

```elixir
config :vicander, :outbox,
  max_retries: 10,           # retries after the first attempt (default 10)
  backoff_base_ms: 1_000,    # the first retry waits this long, then it doubles (default 1s)
  backoff_max_ms: 300_000    # never wait longer than this (default 5 minutes)
```

A poller option wins over the application config, which wins over the default:
`{DDD.Outbox.Poller, repo: MyApp.Repo, max_retries: 3, backoff_ms: fn retry -> ms end}`.

### Dead letters

An event is dead-lettered only when the system kept failing: infrastructure errors,
exceptions, or an event type that can't be resolved. Business rejections are never dead
letters. When the poller gives up it logs an error, emits a `[:ddd, :outbox, :dead_letter]`
telemetry event (attach a handler to alert), and notifies `DDD.Outbox.DeadLetterHandler`, a
supervised process that applies a policy:

| Policy returns | Effect |
|---|---|
| `:keep` | acknowledge it; it stays dead-lettered for a person to deal with |
| `:replay` | clear the failure state; the poller retries it (handlers that succeeded are skipped) |
| `:discard` | resolve it as discarded |
| `:later` | decide on a later sweep |

The **default policy keeps** every dead letter: the failure is logged and emitted as telemetry,
and a person replays it. Replaying automatically before anyone has looked mostly repeats the
failure, so it is opt-in, for transient causes such as an outage longer than the retries:

```elixir
config :vicander, :dead_letters,
  max_replays: 3,             # default 0: never replay automatically
  replay_cooldown_ms: 60_000, # wait this long after it died
  policy: MyApp.DeadLetterPolicy   # or your own `DDD.Outbox.DeadLetterPolicy`
```

The database is the source of truth. The handler sweeps for unresolved dead letters when it
starts and every minute, so a crash and restart (or a lost notification) loses nothing. A
policy that raises is logged and treated as `:later`; it cannot crash the handler.

By hand:

```bash
mix vic.outbox.dead_letters         # unresolved ones (--all includes resolved)
mix vic.outbox.replay EVENT_ID      # or --all; fix the cause first
mix vic.outbox.discard EVENT_ID
```

### Setup

`{DDD.Supervisor, handlers: [...]}` (see *Setup* at the top) starts the poller and the
dead-letter handler. Handlers are subscribed first, so an event is never delivered to an empty
list. `mix vic.gen.outbox_migration` creates the `domain_events` and `event_deliveries` tables.

Limits: handler cycles (A causes B causes A) are not detected, and events are ordered per poll
batch, not across a whole chain. Two handlers saving the same aggregate at the same moment no
longer overwrite each other (see *Optimistic locking*): the loser fails with `:stale_aggregate`
and is retried.

## Projections

A read model is a denormalized table kept up to date by events, so a screen that needs "my lists
with their counts" reads one table instead of loading and folding every aggregate.
`DDD.Projection` is an event handler (see *Handlers*), so it is delivered through the outbox and
inherits its guarantees: every event is applied in its own transaction together with its delivery
record, so a retry or a duplicate delivery never counts an event twice.

```elixir
defmodule MyApp.Projections.ListSummary do
  alias MyApp.Events.{ListCreated, ItemAdded, ItemCompleted}

  use DDD.Projection, table: "list_summaries", key: :list_id,
    events: [ListCreated, ItemAdded, ItemCompleted]

  projection do
    description "One row per list: title and counts"
    field :list_id, :uuid
    field :title, :string
    field :open_count, :integer, default: 0
    field :done_count, :integer, default: 0
  end

  on %ListCreated{} = e, do: {:upsert, %{title: e.title}}
  on %ItemAdded{}, do: {:inc, :open_count, 1}
  on %ItemCompleted{}, do: {:inc, open_count: -1, done_count: 1}
end

MyApp.Projections.ListSummary.subscribe()     # before the poller starts
```

The row is keyed by the event's `aggregate_id` (`key_from:` picks another event field). An `on`
clause returns what to do to that row: `{:upsert, map}` (create with the field defaults, or set
these fields), `{:update, map}` (only if the row exists), `{:inc, field, n}` (the database adds,
so concurrent events never overwrite each other), `:delete`, `:skip`, a list of these, or
`{:error, reason}` (a rejection, like in any handler). Events can arrive before the row exists:
an increment creates it.

* **Table.** `mix vic.gen.migration MyApp.Projections.ListSummary` writes the migration.
* **Reading.** `get/1`, and `list/1`, `count/1`, `page/1`, `slice/1` with the filters, orders and
  cursors above. Rows are plain maps.
* **Consistency.** Eventually consistent: it trails by the time the outbox takes. Decisions read
  the aggregate, never a projection.
* **Lag.** `lag/0` returns `%{pending: n, oldest_pending_age_ms: ms}`: the events of its types
  that no delivery record covers yet (discarded dead letters excluded).
* **Rebuild.** `mix vic.projection.rebuild MyApp.Projections.ListSummary` (or `rebuild/0`)
  empties the table and replays every stored event of its types, in order. Use it after fixing an
  `on` clause, or to build a new projection from history. The events must still be in
  `domain_events`. Readers see the table fill up again while it runs, so do it in a quiet period;
  if it fails part-way the error says the projection is partial, and running it again is safe.

The example app has one: `TodoApp.Application.Projections.TodoList.ListStats` (items added and completed per
list). It lives in the application layer, beside the query that reads it (`list_activity`): a
projection is an event handler that maintains a read model, and the framework hides the SQL, so
nothing in it is specific to an adapter. Only the repositories, which the domain declares as
ports, sit behind `impl/0`.

## Testing your application

`DDD.Test` has the assertions an application's tests keep writing:

```elixir
import DDD.Test

{:ok, list} = TodoList.complete_item(list, item.id)
assert_event_emitted(list, ItemCompleted, item_id: item.id)   # returns the event
refute_event_emitted(list, ListReopened)

assert_error_code(TodoList.complete_item(list, item.id), :already_completed)   # returns the error

{:ok, _} = Commands.AddItem.call(...)
drain_outbox()      # delivers the saved events to the subscribed handlers, now
```

In tests, start the framework with a poller that doesn't run by itself
(`{DDD.Supervisor, handlers: [...], poller: [interval_ms: 600_000]}`) and call `drain_outbox/0`
when a test needs the handlers to have run, or pass `poller: false` and test the handlers
directly. `DDD.InMemoryRepository` replaces a Postgres adapter in tests that don't need a
database. The example app's `TodoApp.DataCase` shows the Ecto sandbox setup.

## Observability

Every framework event is a `:telemetry` event; `DDD.Telemetry` has the full catalogue.

| what | event |
|---|---|
| a command or query | `[:ddd, :command]` / `[:ddd, :query]` spans, with `:result`, `:error_codes`, `:error_kind` |
| a command re-run after a version conflict | `[:ddd, :command, :retry]` |
| a lost optimistic-lock race | `[:ddd, :repository, :conflict]` |
| a handler delivery | `[:ddd, :handler, :deliver]` span, with `:outcome` (`:delivered`, `:skipped`, `:rejected`, `:error`) |
| the outbox | `[:ddd, :outbox, :poll \| :published \| :retry \| :dead_letter]` |
| a projection rebuild | `[:ddd, :projection, :rebuild]` span |
| outbox and projection gauges | `[:ddd, :outbox, :stats]`, `[:ddd, :projection, :lag]` |

The gauges are read from the database, so emit them on a timer (for example with
`:telemetry_poller`): `DDD.Telemetry.report(MyApp.Repo, [MyApp.Projections.ListSummary])`. A
stuck outbox shows up as a growing `oldest_pending_age_ms`, and `dead_letters` above zero means
someone has to act (`mix vic.outbox.dead_letters`).

**Health.** `DDD.Health.check/1` answers `:ok`, `:degraded` (unresolved dead letters, an event or a
projection waiting longer than its threshold) or `:unhealthy` (the database does not answer):

```elixir
config :vicander, :health,
  projections: [MyApp.Projections.ListSummary],
  max_outbox_age_ms: 60_000, max_dead_letters: 0, max_projection_lag_ms: 60_000
```

The result is JSON-encodable: serve it from a Plug route or a Phoenix controller, or list
`DDD.Health.Query` in an MCP server's `queries:`. `mix vic.health [--json]` prints it and exits
non-zero unless `:ok`, for a deploy gate or a container probe.

## Pending work

Known gaps, in the order they matter. None is hidden: each was found and decided on.

* **Concurrent first saves.** Optimistic locking guards every save of an existing aggregate, and
  a new aggregate whose id already exists is a `:stale_aggregate` conflict. Two *simultaneous*
  first saves of the same new id can still both pass that check, and the second insert then fails
  with a raw constraint error instead of a `DDD.Error`. Ids are UUIDv7, so this only happens when
  the same new struct is saved twice at once.
* **Projection ordering.** A projection applies events in delivery order, which follows
  `occurred_at` for one aggregate but not across aggregates (they are delivered concurrently).
  Its `on` clauses should be commutative (increments, upserts
  of independent fields) rather than depend on strict order; events carry no aggregate version
  yet that a projection could use to detect an out-of-order one.
* **Outbox lease per batch.** A claimed batch of up to 20 events shares one 30-second lease.
  With slow handlers the unprocessed tail can be claimed again by another node. Renew the lease
  per event, or claim fewer events.
* **Logged parameters.** `DDD.Command` and `DDD.Query` log every parameter value at debug level
  (when a command or query starts). There is no way to keep a password or token out of that log
  yet, so don't enable debug logging in production.


## Example application

`todo_app` (a sibling project, `../todo_app`) is a complete application on top of the framework: four layers
(domain, application, infrastructure, interface) with the layering enforced by
[`boundary`](https://hex.pm/packages/boundary), aggregates with specifications, commands and
queries (paged and cursor listings), a read model, event handlers, and an MCP server. It is the
first thing to read to see how the pieces fit, and its test suite is the framework's integration
test.

```elixir
alias TodoApp.Application.{Commands, Queries}

{:ok, user} = Commands.User.RegisterUser.call(%{name: "Ann", email: "ann@example.com"})
{:ok, list} = Commands.TodoList.CreateList.call(%{owner_id: user.id, name: "Home"})
{:ok, list} = Commands.TodoList.AddItem.call(%{list_id: list.id, title: "Buy milk"})
{:ok, open} = Queries.TodoList.OpenItems.call(%{list_id: list.id})
```
