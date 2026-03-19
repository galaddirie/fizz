# Implementation Prompts by Phase

Each prompt below is self-contained and designed to be handed to a coding agent. Phases build on each other — do not start a phase until its predecessors are complete and passing tests.

---

## Phase 1: Workflow Definitions

### Spec

`.spec/specs/workflow-definitions.spec.md`

### Goal

Implement the Ecto schemas, migrations, embedded structs, context module, and validations for workflow definitions and their versioned snapshots. This is the authored source-of-truth layer — no compilation or execution yet.

### What Already Exists

- `Fizz.Steps.Registry` — ETS-based step type registry with `get/1`, `all/0`. Use it for `type_id` validation.
- `Fizz.Graph` — DAG abstraction with `from_workflow/2`, `topological_sort/1`, `validate/2`. Use it for acyclicity checks.
- `Fizz.Accounts.Scope` — Caller context struct with `user`, `organization_id`, `project`. All context functions take `scope` as first arg.
- `Fizz.Accounts.Project` — Project schema with `workos_organization_id`.
- `Fizz.Integrations.CredentialsResolver` — Already built; will be needed at publish-time for credential accessibility checks.
- Postgres via `Fizz.Repo`. No SQLite yet.

### Deliverables

**Migration** (`mix ecto.gen.migration create_workflow_definitions`):
- `workflow_definitions` table: `id` (UUID PK), `project_id` (FK to projects), `workos_organization_id` (string, denormalized), `name` (string), `description` (text), `created_by_user_id` (string), `archived_at` (utc_datetime_usec), timestamps. Index on `(project_id)`, `(workos_organization_id)`.
- `workflow_definition_versions` table: `id` (UUID PK), `workflow_definition_id` (FK), `version` (integer), `status` (string, one of "draft"/"published"/"archived"), `steps` (jsonb), `connections` (jsonb), `step_groups` (jsonb), `viewport` (jsonb), `settings` (jsonb), `compiled_hash` (string), `published_at` (utc_datetime_usec), `published_by_user_id` (string), timestamps. Unique index on `(workflow_definition_id, version)`.

**Embedded Schemas** (under `lib/fizz/workflows/embeds/`):
- `Fizz.Workflows.Embeds.Step` — fields: `id` (string, UUID), `type_id` (string), `name` (string), `config` (map), `position` (map with x/y), `notes` (string). The `id` is a stable UUID assigned at creation time and never changes on rename.
- `Fizz.Workflows.Embeds.Connection` — fields: `id` (string, UUID), `source_step_id` (string), `source_output` (string), `target_step_id` (string), `target_input` (string).
- `Fizz.Workflows.Embeds.StepGroup` — fields: `id` (string, UUID), `name` (string), `step_ids` (list of strings), `position` (map), `color` (string), `font_size` (integer), `collapsed` (boolean).

**Schemas**:
- `Fizz.Workflows.WorkflowDefinition` — standard Ecto schema, `belongs_to :project`, `has_many :versions`.
- `Fizz.Workflows.WorkflowDefinitionVersion` — `belongs_to :workflow_definition`, `embeds_many :steps`, `embeds_many :connections`, `embeds_many :step_groups`. `viewport` and `settings` are `:map` fields. Status is an Ecto enum or string field constrained to `~w(draft published archived)`.

**Context Module** (`Fizz.Workflows`):
- `create_definition(scope, attrs)` — Creates definition + initial draft v1 with empty collections. Requires `scope.project`.
- `save_draft(scope, version, attrs)` — Full-document replacement of draft. Runs save-time validation only. Rejects if version is not draft.
- `publish_draft(scope, version)` — Runs publish-time validation. Stamps `published_at`, `published_by_user_id`, `compiled_hash`. For now, `compiled_hash` can be a placeholder SHA256 of the JSON-encoded steps+connections since the compiler doesn't exist yet. Marks status as "published".
- `edit_definition(scope, definition)` — If no draft exists, clones latest published version into a new draft with incremented version number. Returns the draft version.
- `archive_definition(scope, definition)` — Sets `archived_at`. No new runs can start (enforced later when runs exist).
- `get_definition(scope, id)` — Scoped to `scope.project`.
- `list_definitions(scope)` — Scoped to `scope.project`, excludes archived by default.

**Validation** — implement as changeset validations on the version schema:

Save-time (in `save_draft`):
1. Embeds cast successfully (step/connection/group shapes valid)
2. All step `id` values unique within the version
3. All connection `id` values unique
4. Every step `type_id` exists in `Fizz.Steps.Registry`
5. Every connection's `source_step_id` and `target_step_id` reference existing step ids
6. Every `step_group.step_ids` entry references an existing step id
7. No step appears in more than one group
8. Graph is acyclic (use `Fizz.Graph.from_workflow/2` + `topological_sort/1`)

Publish-time (in `publish_draft`, all save-time checks plus):
1. Each step's config validates against its executor's `validate_config/1` (via `Fizz.Steps.Executors.Behaviour.validate_config/2`)
2. At least one entry step (a step with no incoming connections)
3. `compiled_hash` is computed and stored

Expression validation and credential accessibility checks should be stubbed as passing for now — they depend on Phase 2.

### Tests

Write tests in `test/fizz/workflows_test.exs` covering:
- Create definition with initial empty draft
- Save draft with valid steps/connections
- Save draft rejects cyclic graphs
- Save draft rejects unknown type_ids
- Save draft rejects duplicate step ids
- Publish draft stamps published_at and compiled_hash
- Publish draft rejects when no entry step
- Publish draft rejects invalid step config
- Published version is immutable (reject updates)
- Edit after publish clones to new draft
- Archive hides from list queries

### Constraints

- Follow existing patterns: `scope` as first arg, project-scoped queries.
- Step `id` values are stable UUIDs — they do NOT change on rename. The `name` field is presentational only.
- Concurrent editing is out of scope — single-user draft editing assumed.
- Do not create a `Fizz.Workflows.Compiler` module yet — that's Phase 2.
- Remember: Ecto `:string` type for both `string` and `text` columns. Use `Ecto.Changeset.get_field/2` for changeset field access. Don't use map access syntax on structs.

---

## Phase 2: Expression Language + Compilation

### Specs

- `.spec/specs/workflow-expression-language.spec.md`
- `.spec/specs/workflow-compilation-runtime-context.spec.md`

### Goal

Build the expression evaluation engine (wrapping Solid) with the bounded filter catalog, and the workflow compiler pipeline that transforms authored `%WorkflowDefinitionVersion{}` into an executable `%Runic.Workflow{}` plus a `compiled_hash`.

### What Already Exists

- Phase 1 deliverables: `Fizz.Workflows.WorkflowDefinitionVersion` with embedded steps/connections.
- `Fizz.Steps.Registry` — lookup step types, get executor modules.
- `Fizz.Steps.Executors.Behaviour` — executor contract with `execute/3`.
- `{:solid, "~> 1.2"}` — Liquid template engine. See `deps/solid/lib/solid.ex` and `deps/solid/lib/solid/standard_filter.ex`.
- `{:runic, "~> 0.1.0-alpha.4"}` — Workflow execution kernel. See `deps/runic/lib/runic.ex`, `deps/runic/lib/workflow/step.ex`.
- `Fizz.Graph` — topological sort, traversal.

### Deliverables

**Expression Engine** (`lib/fizz/workflows/expressions/`):

`Fizz.Workflows.Expressions` — main module:
- `parse(expression_string)` — Parse a Liquid expression via `Solid.parse/2`. Return `{:ok, parsed}` or `{:error, reason}`.
- `validate(expression_string, opts)` — Parse + validate filters against the allowed catalog. `opts` includes `strict_filters: true` and `known_step_ids: [...]` for step reference validation.
- `resolve(access_plan, context)` — Resolve a pre-compiled access plan against runtime context. See access plans below.
- `classify(field_value)` — Determine expression mode: `:literal` (no expressions), `:value` (single naked `{{ }}`), `:template` (mixed text + tags), `:predicate` (boolean comparison).

`Fizz.Workflows.Expressions.Filters` — custom Solid filter module:
Implement ALL Fizz custom filters from the spec: `json`, `parse_json`, `to_int`, `to_float`, `to_bool`, `dig`, `pluck`, `sort_by`, `sort_by_desc`, `where_eq`, `where_ne`, `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `blank`, `present`, `slugify`. Each filter is a public function matching Solid's filter convention.

`Fizz.Workflows.Expressions.AccessPlan` — structs for pre-compiled resolution:
- `Literal` — `%{value: term}` — static value, no resolution needed.
- `ValueExpression` — `%{path: [String.t()], parsed: Solid.Template.t(), filters: [...]}` — naked `{{ }}`, preserves native type.
- `TemplateExpression` — `%{parsed: Solid.Template.t()}` — mixed content, renders to string.
- `PredicateExpression` — `%{parsed: Solid.Template.t()}` — resolves to boolean.
- `CredentialFetch` — `%{provider: String.t(), credential_ref: map()}` — resolved at runtime via credential resolver.

For the fast path: `ValueExpression` with no filters and a simple path like `["steps", step_id, "body"]` should resolve via direct `get_in` without invoking Solid.

**Compiler Pipeline** (`lib/fizz/workflows/compiler/`):

`Fizz.Workflows.Compiler` — main entry point:
- `compile(version)` — Pure function: `%WorkflowDefinitionVersion{}` → `{:ok, %Runic.Workflow{}, compiled_hash}` | `{:error, errors}`.
- Pipeline: normalize → compile expressions → assemble → hash.

`Fizz.Workflows.Compiler.Normalizer` (Phase 1):
- Strip UI-only fields: `position`, `notes`, `viewport`, `settings`, `step_groups`.
- Resolve each step's `type_id` against the registry.
- Topologically sort steps using `Fizz.Graph`.
- Produce lightweight IR structs (plain maps, not module structs — per the `closure_bindings` spec requirement).

`Fizz.Workflows.Compiler.ExpressionCompiler` (Phase 2):
- Walk each step's config map recursively.
- For each string value, classify it and compile to an `AccessPlan`.
- Non-string values become `Literal` access plans.
- Validate all filters against the allowed catalog with `strict_filters: true`.
- Validate all step references against the known step ids in the graph.

`Fizz.Workflows.Compiler.Assembler` (Phase 3):
- Convert normalized IR + compiled access plans into `%Runic.Workflow{}`.
- Each authored step becomes a Runic step with a work function that: (1) resolves config via access plans, (2) calls the executor's `execute/3`.
- Closures must capture only plain maps/lists/scalars — never IR structs.
- Steps whose output is referenced downstream get a companion Runic Accumulator for output capture. Use `state_of()` / `context()` for meta-ref wiring per the spec.
- Wire connections as Runic graph edges.

`Fizz.Workflows.Compiler.Hasher` (Phase 4):
- SHA-256 over execution-relevant content only (step ids, type_ids, configs, connections). Exclude position, notes, viewport, settings, step_groups.
- Two authored versions differing only in UI fields must produce the same hash.

**Runtime Resolver** (`lib/fizz/workflows/runtime/`):

`Fizz.Workflows.Runtime.ConfigResolver`:
- `resolve_config(compiled_config, context)` — Walk the config map, resolve each `AccessPlan` against the runtime context.
- Context structure: `%{input: map, steps: %{step_id => output_map}, workflow: map, env: map}`.

**Integration with Phase 1**:
- Update `Fizz.Workflows.publish_draft/2` to call the real compiler instead of the placeholder hash.
- Publish-time validation now includes expression validation (unknown filters block publish, invalid step references block publish).

### Tests

`test/fizz/workflows/expressions_test.exs`:
- Classify literal, value, template, predicate expressions
- Resolve value expression preserving native type (list stays list, not string)
- Resolve template expression to string
- Validate rejects unknown filters with strict mode
- Custom filters: test each Fizz filter
- Step reference validation rejects non-existent step ids

`test/fizz/workflows/compiler_test.exs`:
- Compile a simple 2-step workflow → produces valid `%Runic.Workflow{}`
- UI-only edits produce identical `compiled_hash`
- Execution-relevant edits produce different `compiled_hash`
- Step groups are excluded from hash and IR
- Expressions are pre-compiled into access plans (not re-parsed at runtime)

`test/fizz/workflows/runtime/config_resolver_test.exs`:
- Resolve `{{ input.orders }}` to native value
- Resolve `Hello {{ input.name }}` to string
- Resolve `{{ steps.<uuid>.body }}` from accumulator context
- Fast path: simple lookup without Solid invocation

### Constraints

- Step IDs are stable UUIDs. Expression references like `{{ steps.<uuid>.body }}` use the UUID directly. Renaming a step does NOT change the UUID and does NOT break expressions.
- The expression spec's `rename_sensitivity` requirement is effectively satisfied by stable UUIDs — renames don't affect step ids.
- Compiler-generated closures must NOT capture IR structs. Extract needed fields into plain maps before closure capture.
- For Runic meta-ref wiring: use explicit `meta_refs` options on `Runic.step()` rather than relying on macro detection. See `.spec/decisions/programmatic-meta-ref-wiring.md`.
- The compiler must carry a version identifier. Store it in the compiled artifact metadata.
- Don't implement the full Runic Runner or execution loop yet — that's Phase 4. The compiler just produces the workflow struct.

---

## Phase 3: Storage + Ownership

### Specs

- `.spec/specs/workflow-storage.spec.md`
- `.spec/specs/workflow-ownership.spec.md`

### Goal

Build the per-execution SQLite store adapter (implementing Runic's `Store` behaviour) and the Postgres lease+fencing protocol. These are the infrastructure prerequisites for actually running workflows.

### What Already Exists

- `{:runic, "~> 0.1.0-alpha.4"}` — provides `Runic.Runner.Store` behaviour. Check `deps/runic/` for the exact callbacks.
- `Fizz.Repo` — Postgres via Ecto.
- No Exqlite dependency yet — you will need to add `{:exqlite, "~> 0.25"}` to `mix.exs`.
- Oban is configured in the supervision tree.
- `Fizz.Accounts.Scope` and `Fizz.Accounts.Project` for tenant scoping.

### Deliverables

**Add Dependencies** in `mix.exs`:
- `{:exqlite, "~> 0.25"}` — SQLite driver for per-execution databases.

**Migration** (`mix ecto.gen.migration create_workflow_run_leases`):
- `workflow_run_leases` table: `run_id` (UUID PK — will FK to workflow_runs later), `owner_node` (string), `fence_token` (bigint, default 0), `checkpoint_seq` (bigint, default 0), `lease_expiry` (utc_datetime_usec). Index on `(lease_expiry)` for expired-lease scans.

**SQLite Store Adapter** (`lib/fizz/workflows/store/sqlite_store.ex`):

`Fizz.Workflows.Store.SqliteStore` implementing Runic's Store behaviour:

- `init(run_id, opts)` — Create/open SQLite file at `{data_dir}/{org_id}/{project_id}/{hash[0:2]}/{hash[2:4]}/{run_id}.sqlite`. Set `PRAGMA journal_mode=WAL`, `PRAGMA foreign_keys=ON`. Create tables: `workflow_log (id INTEGER PRIMARY KEY, data BLOB, created_at TEXT)`, `shard_fence (id INTEGER PRIMARY KEY, fence_token BIGINT)`, `facts (hash TEXT PRIMARY KEY, value BLOB)`, `meta (key TEXT PRIMARY KEY, value TEXT)`. Set `PRAGMA user_version` to current schema version. Insert initial fence token from lease. The directory structure must match the Litestream directory-mode config so new files are automatically discovered for replication.
- `save(run_id, log, store_state)` — Serialize `log` via `:erlang.term_to_binary(log, [:compressed])`. Validate fence token via two-phase protocol: (1) conditional UPDATE on Postgres `workflow_run_leases` incrementing `checkpoint_seq` only if `fence_token` matches, (2) if Postgres confirms, write to SQLite atomically. Raise `StaleOwnerError` if fence check fails.
- `load(run_id, store_state)` — Read latest log blob from SQLite, deserialize via `:erlang.binary_to_term/1`, return for `Workflow.from_log/1`.
- `save_fact(hash, value, store_state)` — Write individual fact to `facts` table (for hybrid/lazy rehydration support per `fact_level_persistence` spec).
- `load_fact(hash, store_state)` — Read individual fact by content hash.

**Checkpoint Strategy** (`lib/fizz/workflows/store/checkpoint_strategy.ex`):

`Fizz.Workflows.Store.CheckpointStrategy`:
- `should_checkpoint?(strategy, event)` — Returns boolean based on strategy config.
- Strategies: `:every_cycle`, `{:every_n, n}`, `:on_complete`, `:manual`.
- Strategies other than `:every_cycle` accept that progress since last checkpoint is lost on crash.

**Schema Migration on Wake** (`lib/fizz/workflows/store/sqlite_migrations.ex`):

`Fizz.Workflows.Store.SqliteMigrations`:
- `migrate(db)` — Read `PRAGMA user_version`. If lower than current, run forward migrations in order within transactions. If higher, refuse to open (return error).
- Each migration is a numbered function that executes DDL within a transaction and bumps `user_version`.

**Lease Manager** (`lib/fizz/workflows/lease_manager.ex`):

`Fizz.Workflows.LeaseManager` (GenServer):
- `acquire(run_id)` — Attempt lease acquisition: `UPDATE workflow_run_leases SET owner_node = :self, fence_token = fence_token + 1, lease_expiry = now() + interval '30 seconds' WHERE run_id = :run_id AND (lease_expiry < now() OR owner_node = :self) RETURNING fence_token`. Uses raw SQL via `Ecto.Adapters.SQL.query/3`.
- `release(run_id)` — Clear lease (set expiry to past).
- Periodic renewal: every 10 seconds, renew all leases held by this node (extend `lease_expiry`). Use `Process.send_after/3`.
- `list_expired()` — Query for leases past expiry for failover scanning.

**Fence Validation** in SqliteStore (two-phase per spec):
1. Within a Postgres transaction, `UPDATE workflow_run_leases SET checkpoint_seq = checkpoint_seq + 1 WHERE run_id = ? AND fence_token = ? RETURNING checkpoint_seq`.
2. If zero rows updated → fence token is stale → raise `StaleOwnerError`.
3. Only if Postgres confirmed → proceed with SQLite write.
This ensures the stale-owner check is linearized through Postgres, not relying on a bare read.

**Litestream Manager** (`lib/fizz/workflows/store/litestream_manager.ex`):

`Fizz.Workflows.Store.LitestreamManager` (GenServer):

This module manages the Litestream binary as a supervised port process, using **directory-based replication** so a single Litestream process watches the entire workflow data directory tree and automatically discovers/replicates new SQLite files.

**Why not the `{:litestream, "~> 0.4.0"}` Elixir package**: That package is designed for single-database replication (one Ecto repo → one S3 URL). Fizz needs per-execution replication of thousands of databases. Litestream's native directory-mode replication (`dir` + `pattern` + `recursive` + `watch`) is the correct primitive.

**Binary requirement**: The `litestream` binary must be available on `PATH`. In production, install it in the Docker image (`apt-get install litestream` or download from GitHub releases). In development, install via Homebrew (`brew install litestream`). The manager validates the binary exists at startup and logs an error with clear instructions if missing.

**Config generation** — `generate_config/1`:
- Generates a YAML config file at `{data_dir}/litestream.yml` with this structure:
  ```yaml
  dbs:
    - dir: {data_dir}
      pattern: "*.sqlite"
      recursive: true
      watch: true
      replica:
        type: s3
        bucket: {s3_bucket}
        path: {s3_prefix}
        region: {aws_region}
        access-key-id: ${LITESTREAM_ACCESS_KEY_ID}
        secret-access-key: ${LITESTREAM_SECRET_ACCESS_KEY}
        sync-interval: 1s
  ```
- Config is regenerated on restart. Environment variables are expanded by Litestream at runtime (not embedded in the file).

**Lifecycle** — `start_link/1`:
- Accepts opts: `data_dir`, `s3_bucket`, `s3_prefix`, `aws_region`, `bin_path` (optional override).
- On init: validate binary exists, generate config, start `litestream replicate -config {config_path}` via `Port.open/2` with `:binary` and `:exit_status`.
- Monitor the port. If it crashes, log the error and restart (the GenServer supervisor handles this).
- `handle_info({port, {:exit_status, code}}, state)` — log and crash the GenServer so the supervisor restarts it.

**Restore** — `restore/2`:
- `restore(run_id, opts)` — Computes the S3 replica URL from `run_id` + directory structure. Calls `System.cmd("litestream", ["restore", "-o", local_path, replica_url])`. Returns `{:ok, local_path}` or `{:error, reason}`.
- Only runs if the local file does not already exist (safety check).
- Validates the restored file is a valid SQLite database (`PRAGMA integrity_check`).
- After restore, the Litestream directory watcher automatically picks up the file for ongoing replication.

**Status** — `status/0`:
- Returns `:running` or `:down` based on whether the port is alive.

**Passivation support** — `wal_checkpoint/1`:
- `wal_checkpoint(db_path)` — Executes `PRAGMA wal_checkpoint(TRUNCATE)` on the given database to flush all WAL data. Called before local file eviction to ensure Litestream has replicated everything.

**Application** — Add to `Fizz.Application` children:
```elixir
{Fizz.Workflows.Store.LitestreamManager,
  data_dir: Application.get_env(:fizz, :workflow_data_dir),
  s3_bucket: Application.get_env(:fizz, :litestream_s3_bucket),
  s3_prefix: Application.get_env(:fizz, :litestream_s3_prefix),
  aws_region: Application.get_env(:fizz, :litestream_aws_region)}
```

**Runtime config** — Add to `config/runtime.exs`:
```elixir
config :fizz,
  workflow_data_dir: System.get_env("WORKFLOW_DATA_DIR", "priv/workflow_data"),
  litestream_s3_bucket: System.get_env("LITESTREAM_S3_BUCKET"),
  litestream_s3_prefix: System.get_env("LITESTREAM_S3_PREFIX", "workflows"),
  litestream_aws_region: System.get_env("LITESTREAM_AWS_REGION", "us-east-1")
```

Litestream reads `LITESTREAM_ACCESS_KEY_ID` and `LITESTREAM_SECRET_ACCESS_KEY` environment variables automatically — don't pass them through Elixir config.

### Tests

`test/fizz/workflows/store/sqlite_store_test.exs`:
- Init creates SQLite file with correct schema and WAL mode
- Save + load round-trips workflow log
- Save with stale fence token raises `StaleOwnerError`
- Save_fact + load_fact round-trips individual facts
- Schema migration upgrades old user_version
- File is created in the correct directory structure for Litestream discovery

`test/fizz/workflows/lease_manager_test.exs`:
- Acquire lease returns fence token
- Renewal extends expiry
- Expired lease can be claimed by another node
- Concurrent acquisition: only one succeeds (test with two Ecto transactions)

`test/fizz/workflows/store/litestream_manager_test.exs`:
- Config generation produces valid YAML with directory-mode replication
- Config includes correct `dir`, `pattern: "*.sqlite"`, `recursive: true`, `watch: true`
- Restore computes correct S3 replica URL from run_id
- Restore refuses to overwrite existing local file
- Manager reports `:down` status when binary is not available
- Manager reports `:running` status when port is alive

Note: Full integration tests (actual S3 replication) require Litestream binary + S3 credentials. Tag these tests with `@tag :litestream_integration` so they can be skipped in CI without credentials. Unit tests for config generation and path computation don't need the binary.

### Constraints

- SQLite files are opened with WAL mode. No shared/network filesystem.
- Fence validation uses the two-phase Postgres-then-SQLite protocol described in the ownership spec.
- Lease TTL = 30 seconds, renewal cadence = 10 seconds.
- The `StaleOwnerError` must be a dedicated exception module.
- The Litestream binary must be available on `PATH` or at a configured `bin_path`. The LitestreamManager validates this at startup and fails with a clear error message if missing.
- Do NOT use the `{:litestream, "~> 0.4.0"}` Elixir package — it only supports single-database replication. Build the manager directly with `Port.open/2`.
- Directory-based replication means no per-database config changes are needed when executions are created or destroyed.
- `litestream restore` is the cold-start path — it downloads from S3 to local disk. After restore, the directory watcher picks up the file automatically for ongoing replication.
- Don't implement the PassivationSweeper yet — that's Phase 4. But ensure the `wal_checkpoint/1` helper exists for Phase 4 to call before file eviction.

---

## Phase 4: Run Lifecycle + Activity Dispatch

### Specs

- `.spec/specs/workflow-run-lifecycle.spec.md`
- `.spec/specs/workflow-activity-dispatch.spec.md`

### Goal

Build the workflow execution engine: the `WorkflowRun` schema with its status state machine, the `Runner.Worker` GenServer wrapping Runic's Runner, the DynamicSupervisor for Worker management, the activity dispatch loop, and the PassivationSweeper. After this phase, workflows can actually run end-to-end.

### What Already Exists

- Phase 1: `WorkflowDefinition`, `WorkflowDefinitionVersion`, `Fizz.Workflows` context.
- Phase 2: `Fizz.Workflows.Compiler.compile/1` producing `%Runic.Workflow{}` + `compiled_hash`.
- Phase 3: `SqliteStore`, `LeaseManager`, `CheckpointStrategy`, fence validation.
- `Fizz.Steps.Executors.Behaviour` — `execute/3`, `resolve/1`.
- `{:runic, "~> 0.1.0-alpha.4"}` — `Runic.Runner`, `Runic.Workflow`, `Runic.Runner.Worker`.
- Oban for background jobs.

### Deliverables

**Migration** (`mix ecto.gen.migration create_workflow_runs`):
- `workflow_runs` table: `id` (UUID PK), `workflow_definition_id` (FK), `workflow_definition_version_id` (FK), `project_id` (FK), `workos_organization_id` (string), `status` (string), `input` (jsonb), `output` (jsonb), `error` (jsonb), `storage_uri` (string, for cold-tier S3 path), `last_active_at` (utc_datetime_usec), `started_at` (utc_datetime_usec), `completed_at` (utc_datetime_usec), `continued_from_run_id` (UUID, nullable, self-FK for lineage), `compiled_hash` (string), timestamps.
- Indexes: `(project_id, status)`, `(workflow_definition_id)`, `(status, last_active_at)` for passivation sweep, `(continued_from_run_id)`.

**Schema** (`lib/fizz/workflows/workflow_run.ex`):

`Fizz.Workflows.WorkflowRun`:
- Status values: `~w(pending running sleeping passivated completed failed cancelled continued)`.
- `transition_status(run, new_status)` — Changeset function that validates the transition is legal per the defined graph:
  - `pending → running`
  - `running → sleeping | passivated | completed | failed | cancelled | continued`
  - `sleeping → running | passivated | cancelled`
  - `passivated → running`
  - Terminal states (`completed`, `failed`, `cancelled`, `continued`) reject all transitions.
- `touch_last_active(run)` — Updates `last_active_at` to now.

**Context additions** to `Fizz.Workflows`:
- `start_run(scope, definition_version, input)` — Create run in `pending` status. Acquire lease. Compile definition version (or use cached compiled artifact). Open SqliteStore. Start Worker. Transition to `running`.
- `get_run(scope, run_id)` — Project-scoped lookup.
- `list_runs(scope, opts)` — Filterable by status, definition_id. Project-scoped.
- `cancel_run(scope, run_id)` — Transition to `cancelled`. Cancel pending timers (stub for now). Stop Worker.
- `signal_run(scope, run_id, signal_name, payload, signal_id)` — Placeholder for Phase 5.

**Worker** (`lib/fizz/workflows/runner/worker.ex`):

`Fizz.Workflows.Runner.Worker` (GenServer):
- `start_link(opts)` — opts include `run_id`, `workflow` (compiled Runic workflow), `store` (SqliteStore state), `fence_token`, `checkpoint_strategy`, `max_concurrency`.
- State: holds the live `%Runic.Workflow{}`, store state, fence token, in-flight task count, checkpoint strategy.
- Main loop (in `handle_info`):
  1. `Workflow.plan_eagerly(workflow, input)` — identify ready work
  2. `Workflow.prepare_for_dispatch(workflow)` — extract portable runnables
  3. For each runnable (up to `max_concurrency`): dispatch via `Task.Supervisor.async_nolink`
  4. On task completion (`{ref, result}` message): `Workflow.apply_runnable(workflow, result)` — single-writer state advancement
  5. Checkpoint if strategy says so (via `CheckpointStrategy.should_checkpoint?/2`)
  6. Update Postgres `last_active_at`
  7. If workflow is satisfied → transition run to `completed`
  8. If no more ready work and waiting on timer/signal → transition to `sleeping`
  9. Loop back to step 1
- `handle_info(:timeout, state)` — idle timeout, prepare for passivation.
- The dispatch function for each runnable: resolve the step's executor via `Fizz.Steps.Executors.Behaviour.resolve!/1`, call `executor.execute(resolved_config, input, context)`.
- Backpressure: track in-flight count, defer dispatch when at `max_concurrency`.

**Worker Supervisor** (`lib/fizz/workflows/runner/worker_supervisor.ex`):
- DynamicSupervisor, started in `Fizz.Application` supervision tree.
- `start_worker(opts)` — `DynamicSupervisor.start_child/2`.
- `max_children` configuration for node-level backpressure.

**PassivationSweeper** (`lib/fizz/workflows/passivation_sweeper.ex`):

`Fizz.Workflows.PassivationSweeper` (GenServer):
- Periodic scan every 60 seconds (configurable).
- Query runs where `status in ["running", "sleeping"]` and `last_active_at < now() - idle_threshold` (default 10 minutes).
- For each idle run: stop Worker, transition status to `passivated`.
- S3 upload is deferred — for now just stop the Worker and update status.

**Application** — Add to `Fizz.Application` children:
- `{Fizz.Workflows.Runner.WorkerSupervisor, name: Fizz.Workflows.Runner.WorkerSupervisor}`
- `Fizz.Workflows.PassivationSweeper`

### Tests

`test/fizz/workflows/workflow_run_test.exs`:
- Valid status transitions accepted
- Invalid transitions rejected (e.g., completed → running)
- Terminal states reject all transitions

`test/fizz/workflows/runner/worker_test.exs`:
- Start worker with a compiled 2-step workflow → runs to completion
- Worker updates `last_active_at` on step completion
- Worker transitions run to `completed` when workflow is satisfied
- Backpressure: worker defers dispatch when at max_concurrency

`test/fizz/workflows/passivation_sweeper_test.exs`:
- Idle runs beyond threshold are passivated
- Active runs (recent `last_active_at`) are not passivated
- Completed/failed runs are not passivated

`test/fizz/workflows_test.exs` (integration):
- `start_run/3` → run executes steps → transitions to completed
- `cancel_run/2` → transitions to cancelled, worker stopped

### Constraints

- The Worker's apply step is the single-writer boundary. Runic's `apply_runnable/2` is sequential even when dispatch is parallel.
- Use `Task.Supervisor.async_nolink/3` for dispatch — not bare `Task.async`.
- The Worker must handle `{:DOWN, ref, :process, pid, reason}` for crashed tasks and apply the result as an error.
- Checkpoint writes go through `SqliteStore.save/3` which enforces fence validation.
- `run_context` is built at worker start from durable metadata (definition version, project, org) and must be rebuildable on resume — never serialized into the checkpoint.
- Don't implement timer creation/delivery or signal routing yet — stub those as no-ops. Phase 5 adds them.
- Use `start_supervised!/1` in tests for process cleanup.

---

## Phase 5: Durable Timers + Signal Delivery

### Specs

- `.spec/specs/workflow-durable-timers.spec.md`
- `.spec/specs/workflow-signal-delivery.spec.md`

### Goal

Add durable timer persistence and polling, and the signal inbox with dedup and delivery routing. These extend the running execution engine with the ability to sleep for arbitrary durations and receive external events.

### What Already Exists

- Phase 4: `WorkflowRun` with status state machine, `Runner.Worker`, `LeaseManager`, `SqliteStore`, `PassivationSweeper`.
- Postgres via `Fizz.Repo`.
- Phoenix PubSub for local notifications.

### Deliverables

**Migration** (`mix ecto.gen.migration create_durable_timers_and_signals`):

`durable_timers` table:
- `id` (UUID PK), `run_id` (FK to workflow_runs), `step_id` (string — the step that produced the timer intent), `timer_name` (string), `project_id` (FK to projects), `workos_organization_id` (string), `fire_at` (utc_datetime_usec), `status` (string: "pending"/"firing"/"fired"/"cancelled"), `payload` (jsonb, nullable), `claimed_at` (utc_datetime_usec, nullable), `claimed_by` (string, nullable — node identifier), timestamps.
- Indexes: `(fire_at) WHERE status = 'pending'` for polling, `(run_id) WHERE status = 'pending'` for cancellation, `(claimed_at) WHERE status = 'firing'` for stale recovery.

`signal_inbox` table:
- `id` (UUID PK), `run_id` (FK to workflow_runs), `signal_id` (string — caller-provided idempotency key), `signal_name` (string), `payload` (jsonb), `status` (string: "pending"/"delivered"/"skipped", default "pending"), `project_id` (FK to projects), `workos_organization_id` (string), `delivered_at` (utc_datetime_usec, nullable), timestamps.
- Unique index on `(run_id, signal_id)` for dedup.
- Index on `(run_id) WHERE status = 'pending'` for delivery scan.

**Durable Timers**:

`Fizz.Workflows.DurableTimer` (Ecto schema):
- Standard schema for the `durable_timers` table.

`Fizz.Workflows.TimerPoller` (GenServer):
- Polls every 1 second (configurable).
- Query: `SELECT * FROM durable_timers WHERE status = 'pending' AND fire_at <= now() ORDER BY fire_at LIMIT 50 FOR UPDATE SKIP LOCKED`. Transition matched rows to `'firing'`, set `claimed_at` and `claimed_by`.
- For each claimed timer: wake the target workflow run. If run is `passivated`, acquire lease and start Worker. Deliver `TimerFired` event as workflow input via `Runner.Worker.deliver_event/2`.
- After successful delivery, transition timer to `'fired'`.
- Stale FIRING recovery: also scan for `status = 'firing' AND claimed_at < now() - claim_ttl`. Reset stale timers back to `'pending'` so they can be re-claimed. This prevents stranded timers when a poller crashes mid-delivery.
- Short timers (under passivation threshold): the Worker remains HOT and timer is delivered directly without passivation cycle.

Timer creation integration in Worker:
- When a step produces a `sleep(duration)` or `schedule_at(datetime)` intent, the Worker inserts a `durable_timers` row and transitions the run to `sleeping`.
- Timer intent convention: extend the executor return type with tagged tuples. An executor returning `{:sleep, duration, output}` or `{:schedule_at, datetime, output}` signals a timer intent. The Worker's apply-runnable path detects these tagged returns, extracts the `fire_at` timestamp (computed as `DateTime.add(DateTime.utc_now(), duration, :second)` for sleep), inserts the `durable_timers` row via `Fizz.Workflows.create_timer/4`, and transitions the run to `sleeping` if the timer is beyond the idle threshold.
- Short timer optimization: if `fire_at` is within the idle_timeout_ms threshold, keep the Worker hot. The timer row is still persisted for crash recovery, but the Worker does not passivate.

Timer cancellation in `Fizz.Workflows.cancel_run/2`:
- `UPDATE durable_timers SET status = 'cancelled' WHERE run_id = ? AND status = 'pending'`.

**Signal Delivery**:

`Fizz.Workflows.SignalInbox` (Ecto schema):
- Standard schema for the `signal_inbox` table. Uses `status` field with values "pending", "delivered", "skipped" instead of a bare boolean — cleaner for tracking terminal-run skip semantics.

`Fizz.Workflows.SignalRouter`:
- `accept_signal(run_id, signal_id, signal_name, payload)` — Insert into inbox with `ON CONFLICT (run_id, signal_id) DO NOTHING` for idempotent acceptance. Signal is always accepted into inbox regardless of run status.
- After insert, attempt delivery: if run is active (Worker alive), deliver directly via `Runner.Worker.deliver_event/2`. If dormant, trigger wake-up (acquire lease, start Worker, deliver).
- If run is terminal, signal is recorded but delivery is skipped.
- Ordering: delivery order is NOT guaranteed to match submission order.

Optionally implement LISTEN/NOTIFY as a latency optimization — but polling catch-up is the authoritative path. For v1, polling-only is acceptable.

**Worker Integration**:
- Add `deliver_event(pid, event)` to Worker — accepts timer fires and signals, feeds them into the Runic workflow as new input facts.
- After delivering a signal, mark it as `status = 'delivered'` with `delivered_at` timestamp in the inbox. Signals to terminal runs are marked `status = 'skipped'`.

**Forward dependency note**: The signal inbox and `SignalRouter.accept_signal/4` API will be reused by the trigger system in Phase 7. When a run-level trigger fires, `TriggerFireWorker` delivers the event via `accept_signal` rather than creating a new run. Design the signal inbox API to be trigger-agnostic — it accepts signals from any source.

### Tests

`test/fizz/workflows/timer_poller_test.exs`:
- Timer created → poller fires it after `fire_at`
- Cancelled timer is skipped by poller
- Concurrent pollers claim disjoint batches (use `FOR UPDATE SKIP LOCKED`)
- Stale FIRING timer is reset to PENDING after claim TTL expiry

`test/fizz/workflows/signal_router_test.exs`:
- Accept signal into inbox
- Duplicate `(run_id, signal_id)` collapses to one record
- Same `signal_id` on different runs accepted independently
- Signal to terminal run is recorded but not delivered
- Different `signal_id` with same payload are distinct deliveries

Integration:
- Workflow sleeps → timer fires → workflow resumes → completes
- External signal delivered to running workflow → triggers step
- Signal to passivated workflow → wakes it up

### Constraints

- Timer state machine: PENDING → FIRING → FIRED | CANCELLED, plus FIRING → PENDING for stale claim recovery.
- Signal dedup is scoped to `(run_id, signal_id)` — not global.
- Signals are always accepted into the inbox regardless of run status. Delivery (to the workflow graph) is conditional on non-terminal status.
- Don't implement LISTEN/NOTIFY in v1 unless time permits — polling is sufficient and authoritative.
- The kernel boundary: Runic SchedulerPolicy handles in-process retries/timeouts. Durable timers are exclusively a platform concern for waits surviving Worker shutdown.
- Use `start_supervised!/1` in tests. Use `Process.monitor/1` + `assert_receive {:DOWN, ...}` instead of `Process.sleep`.

---

## Phase 6: Error Handling + Continuation

### Specs

- `.spec/specs/workflow-error-handling.spec.md`
- `.spec/specs/workflow-continuation.spec.md`

### Goal

Layer retry/skip/fail policies onto the dispatch loop, implement the ContinueAsNew boundary with lineage tracking, and add the stable `workflow_id` addressing for signal routing across continuations.

### What Already Exists

- Phase 4: Worker dispatch loop, `WorkflowRun` state machine, DynamicSupervisor.
- Phase 5: `DurableTimer`, `SignalRouter`, `SignalInbox`.
- `Fizz.Steps.Executors.Behaviour` — executors return `{:ok, output}`, `{:error, reason}`, or `{:skip, reason}`.
- Runic's `SchedulerPolicy` for in-process retry/backoff.

### Deliverables

**Error Handling** — modifications to `Runner.Worker`:

Retry policy integration:
- Each step type can declare a default retry policy. At dispatch time, wrap the executor call with a `PolicyDriver` that respects: `max_retries`, `backoff` (`:exponential` | `:linear`), `base_delay_ms`, `timeout_ms`.
- `on_failure: :fail` (default) — when retries exhausted, mark step as failed, transition run to `failed`, stop dispatching.
- `on_failure: :skip` — when retries exhausted, mark step as skipped, continue workflow past the failed step. Downstream steps that depend on the skipped step's output receive a skip indicator.
- `{:skip, reason}` returned directly from executor also triggers skip without retry.
- Durable mode: when `execution_mode: :durable`, emit `RunnableDispatched`/`RunnableCompleted`/`RunnableFailed` events to workflow log for crash recovery.

`Fizz.Workflows.Runner.PolicyDriver`:
- `execute_with_policy(work_fn, policy)` — Wraps execution with retry loop, backoff delays, timeout enforcement.
- Returns `{:ok, result}`, `{:error, reason, attempts}`, or `{:skip, reason}`.
- Each retry uses the same stable runnable identity (for external idempotency).

Worker crash recovery path:
- On Worker restart (DynamicSupervisor): `SqliteStore.load/2` → `Workflow.from_log/1` → `Workflow.pending_runnables/1` → re-dispatch interrupted work.
- Rebuild `run_context` from durable metadata, never from deserialized checkpoint.

**Continuation (ContinueAsNew)**:

**Migration** (`mix ecto.gen.migration add_workflow_address`):
- Add `workflow_address_id` (UUID, nullable) column to `workflow_runs`. This is the stable logical workflow identity that persists across continuations.
- Add `active_run_id` (UUID, nullable, FK to workflow_runs) column or a separate `workflow_addresses` table: `id` (UUID PK), `workflow_definition_id` (FK), `project_id` (FK), `active_run_id` (UUID FK to workflow_runs), timestamps.

`Fizz.Workflows.continue_as_new(scope, run_id, carry_forward_payload)`:
1. Verify the run is at a quiescent checkpoint boundary (no in-flight runnables).
2. Checkpoint parent run.
3. Create child run: same `workflow_definition_id` and `workflow_definition_version_id`, `continued_from_run_id` = parent's `run_id`, same `workflow_address_id`.
4. Update `workflow_addresses.active_run_id` to child.
5. Transition parent to `continued` (terminal).
6. Start child Worker with the carry-forward payload as initial input.
7. If child creation fails at any step, do NOT transition parent to `continued` — leave parent in prior state and return error.

Carry-forward rules:
- Only the explicit payload crosses. No in-flight runnables, raw graph internals, or hidden accumulator state.
- Undelivered parent signals remain with parent. Child starts with empty inbox.

Signal routing via stable address:
- `Fizz.Workflows.signal_workflow(scope, workflow_address_id, signal_id, signal_name, payload)` — Resolve `active_run_id` from `workflow_addresses`, route signal to that run's inbox. Callers don't need to track individual `run_id` values across continuations.

Lineage queries:
- `Fizz.Workflows.get_lineage(scope, run_id)` — Follow `continued_from_run_id` chain. Returns ordered list of run summaries.
- `Fizz.Workflows.get_lineage_for_address(scope, workflow_address_id)` — All runs sharing the same address, ordered by creation.

### Tests

`test/fizz/workflows/runner/policy_driver_test.exs`:
- Retry with exponential backoff succeeds on 3rd attempt
- Exhausted retries with `:fail` returns error
- Exhausted retries with `:skip` returns skip
- Timeout enforcement kills long-running execution

`test/fizz/workflows/error_handling_test.exs` (integration):
- Step fails → retries → succeeds → workflow completes
- Step fails → retries exhausted → workflow transitions to FAILED
- Step with `on_failure: :skip` → skipped → workflow continues
- Worker crash → restart → restores from checkpoint → re-dispatches pending work

`test/fizz/workflows/continuation_test.exs`:
- ContinueAsNew creates child run with carry-forward payload
- Parent transitions to `continued` (terminal)
- Child shares same `workflow_address_id`
- Lineage chain is navigable (A → B → C)
- Signal to `workflow_address_id` routes to active run
- Child creation failure leaves parent in prior state
- Undelivered parent signals stay with parent

### Constraints

- ContinueAsNew is an EXPLICIT action — not automatic. Log-size policies may recommend it, but the decision is at the workflow/runtime level.
- Carry-forward payload must be serializable (no process refs, no closures).
- Parent signals are NOT inherited by child.
- `workflow_address_id` is a `should` / `evolving` requirement — implement it but expect the API to evolve.
- v1 has NO automatic compensation or rollback. Workflows needing undo must author it as forward steps.
- `run_context` must be reconstructed on resume, never deserialized from checkpoints.
- Use `Process.monitor/1` in tests, not `Process.sleep/1`.

---

## Phase 7: Trigger Foundation

### Specs

- `.spec/specs/workflow-triggers.spec.md`

### Goal

Build the trigger registration infrastructure, fire routing worker, trigger registry cache, and compiler integration. This phase creates the machinery that manages *what* is listening and *how* events route to runs — but does not implement any specific trigger type (manual, webhook, schedule). Those are wired in Phase 8.

The foundational insight from `docs/plans/triggers-design.md` is that **triggers and signals are the same delivery mechanism with different registration lifecycles**. A trigger is a signal with a persistent, externally-registered source. This phase builds the registration and routing layer on top of the signal inbox from Phase 5.

### What Already Exists

- Phase 5: `Fizz.Workflows.SignalInbox`, `Fizz.Workflows.SignalRouter`, `Fizz.Workflows.DurableTimer`, `Fizz.Workflows.TimerPoller`. Signal delivery to active and dormant runs.
- Phase 6: Error handling, ContinueAsNew, `workflow_address_id`.
- `Fizz.Steps.Registry` — ETS-backed step type registry (different concern from trigger registration registry).
- `Fizz.Steps.Definition` macro with `kind: :trigger` support.
- Existing trigger executor stubs: `manual_input.ex`, `schedule_trigger.ex`, `on_chat_trigger.ex` — define metadata and passthrough `execute/3` but no registration infrastructure.
- `docs/plans/triggers-design.md` — complete design document.
- Oban configured with queues `default`, `workspaces`, `workspaces_maintenance`.

### Deliverables

**Trigger Behaviour** (`lib/fizz/triggers/behaviour.ex`):

`Fizz.Triggers.Behaviour`:
- `@callback registration_spec(config :: map(), context :: map()) :: {:ok, Fizz.Triggers.RegistrationSpec.t()} | {:error, term()}` — Returns a registration specification describing the external source. Called at publish time (definition-level) and subscribe time (run-level).
- `@callback match?(config :: map(), incoming_event :: map()) :: boolean()` — Filter predicate for shared channels. Default: always true. Mark as `@optional_callbacks`.
- `@callback normalize_event(config :: map(), raw_event :: map()) :: {:ok, map()} | {:error, term()}` — Transforms raw external event into the trigger step's output schema.

**Registration Spec** (`lib/fizz/triggers/registration_spec.ex`):

`Fizz.Triggers.RegistrationSpec`:
- Struct: `kind` (atom: `:manual | :webhook | :schedule | :polling | :subscription | :chat`), `params` (map), `dedup_key` (string, nullable).
- `defstruct [:kind, :params, :dedup_key]`.

**Migration** (`mix ecto.gen.migration create_trigger_tables`):

`trigger_registrations` table — copy the exact schema from `docs/plans/triggers-design.md` Section 6.1:
- `id` (UUID PK), `workflow_definition_id` (FK), `definition_version_id` (FK), `step_id` (string), `project_id` (FK), `workos_organization_id` (string), `run_id` (UUID FK nullable — NULL = definition-level, non-NULL = run-level), `kind` (string, CHECK IN manual/webhook/schedule/polling/subscription/chat), `status` (string, default 'active', CHECK IN active/paused/errored/inactive/firing), `registration_params` (jsonb, default '{}'), `config_digest` (string), `webhook_path` (string nullable), `webhook_secret` (string nullable), `cron_expression` (string nullable), `next_fire_at` (utc_datetime_usec nullable), `cursor` (jsonb nullable), `poll_interval_ms` (integer nullable), `last_polled_at` (utc_datetime_usec nullable), `batch_size` (integer, default 100), `error_message` (string nullable), `consecutive_errors` (integer, default 0), `last_error_at` (utc_datetime_usec nullable), timestamps.
- Unique indexes: `(definition_version_id, step_id) WHERE run_id IS NULL` for definition-level dedup, `(run_id, step_id) WHERE run_id IS NOT NULL` for run-level dedup.
- Unique index: `(webhook_path) WHERE webhook_path IS NOT NULL AND status = 'active'` for webhook routing.
- Index: `(next_fire_at) WHERE kind = 'schedule' AND status = 'active'` for schedule polling.
- Index: `(project_id, status)` for UI queries.

`trigger_events` table — from Section 6.3:
- `id` (UUID PK), `trigger_registration_id` (FK), `project_id` (FK), `workos_organization_id` (string), `event_id` (string), `event_data` (jsonb), `status` (string, default 'pending', CHECK IN pending/processing/fired/skipped/failed), `run_id` (UUID nullable), timestamps including `processed_at` (utc_datetime_usec nullable).
- Unique index: `(trigger_registration_id, event_id)` for dedup.
- Index: `(created_at) WHERE status IN ('fired','skipped','failed')` for cleanup.

**Migration** (`mix ecto.gen.migration add_triggered_by_to_workflow_runs`):
- Add `triggered_by` (jsonb, nullable) column to `workflow_runs`. Structure: `{"trigger_registration_id": "uuid", "trigger_step_id": "step-id", "trigger_kind": "webhook", "event_id": "dedup-key", "received_at": "iso8601"}`.

**Schemas**:

`Fizz.Triggers.TriggerRegistration` (`lib/fizz/triggers/trigger_registration.ex`):
- `use Fizz.Schema`. All fields from the table. Status and kind as string fields (not Ecto enums — keep consistent with `WorkflowRun`). Changeset for upsert with `unique_constraint` on the dedup indexes.

`Fizz.Triggers.TriggerEvent` (`lib/fizz/triggers/trigger_event.ex`):
- `use Fizz.Schema`. All fields from the table. `unique_constraint` on `[:trigger_registration_id, :event_id]`.

Update `Fizz.Workflows.WorkflowRun` (`lib/fizz/workflows/workflow_run.ex`):
- Add `field :triggered_by, :map` to schema.

**Trigger Registry** (`lib/fizz/triggers/registry.ex`):

`Fizz.Triggers.Registry` (GenServer):
- On init: load all active `trigger_registrations` from Postgres into ETS. Create ETS tables indexed by `webhook_path`, by `{project_id, kind}`.
- Subscribe to Postgres LISTEN on `trigger_registrations` channel for real-time sync.
- Periodic full refresh every 60 seconds as LISTEN/NOTIFY fallback.
- Public APIs: `get_by_webhook_path(path)` → `{:ok, registration} | :error`, `list_by_kind(project_id, kind)` → `[registration]`, `list_by_project(project_id)` → `[registration]`.

**TriggerFireWorker** (`lib/fizz/triggers/workers/trigger_fire_worker.ex`):

`Fizz.Triggers.Workers.TriggerFireWorker` (Oban.Worker):
- Queue: `:triggers`. Max attempts: 5.
- Unique: `[keys: [:trigger_registration_id, :event_id], period: 300]` — 5-minute dedup window.
- Args: `trigger_registration_id`, `event_id`, `normalized_data`.
- Routing logic:
  - Fetch registration by id.
  - If `registration.run_id == nil` → definition-level: create a new workflow run via `Fizz.Workflows.start_run/3` with `triggered_by` metadata.
  - If `registration.run_id != nil` → run-level: deliver signal via `Fizz.Workflows.signal_run/5`.
- Record event in `trigger_events` table.

**RegistrationSyncWorker** (`lib/fizz/triggers/workers/registration_sync_worker.ex`):

`Fizz.Triggers.Workers.RegistrationSyncWorker` (Oban.Worker):
- Cron: every minute (`"* * * * *"`).
- Reconciliation:
  1. Find published definition versions with missing registrations → create them.
  2. Find registrations for unpublished/archived versions → deactivate.
  3. Find errored registrations past cooldown (e.g., 5 minutes since last error) → reset to active.
  4. Prune terminal trigger_events older than 7 days.

**Registration Manager** (`lib/fizz/triggers/registration_manager.ex`):

`Fizz.Triggers.RegistrationManager`:
- `sync_on_publish(definition_version)` — Read `trigger_manifest` from compiled workflow's `fizz_metadata`. For each trigger: resolve executor, call `registration_spec/2`, upsert registration with `config_digest` for idempotency. For webhook triggers: generate `webhook_path` and `webhook_secret`. For schedule triggers: compute initial `next_fire_at`.
- `deactivate_stale_registrations(definition_version)` — Deactivate registrations for previous published versions of the same definition.

**Compiler Integration**:

Modify `Fizz.Workflows.Compiler.Normalizer` (`lib/fizz/workflows/compiler/normalizer.ex`):
- In the validation phase, check that all steps with `kind: :trigger` (resolved via the step registry) have in-degree zero. Return a compile error like `{:error, [{step_id, "trigger steps must be graph roots with no incoming connections"}]}` if violated.

Modify `Fizz.Workflows.Compiler.Assembler` (`lib/fizz/workflows/compiler/assembler.ex`):
- After assembling the Runic workflow, extract trigger steps and build the `trigger_manifest` list. Each entry: `%{step_id: step.id, type_id: step.type_id, config: step.config}`.
- Store in `fizz_metadata`: `%{compiler_version: N, trigger_manifest: [...]}`.

Modify `Fizz.Workflows.Compiler` (`lib/fizz/workflows/compiler.ex`):
- Bump `@compiler_version` from current value (3) to 4.

**Publish Hook**:

Modify `Fizz.Workflows.publish_draft/2` (`lib/fizz/workflows.ex`):
- After successful compilation and Repo update, call `Fizz.Triggers.RegistrationManager.sync_on_publish/1` with the published version.
- If registration sync fails, log the error but do not fail the publish — the `RegistrationSyncWorker` will catch up.

**Definition Macro**:

Modify `Fizz.Steps.Definition` (`lib/fizz/steps/definition.ex`):
- When `kind: :trigger`, automatically inject `@behaviour Fizz.Triggers.Behaviour`.
- Add a default `match?/2` implementation that returns `true` (since it's an optional callback).

**Context Module** (`lib/fizz/triggers.ex`):

`Fizz.Triggers`:
- `get_registration!(id)` — fetch by id or raise.
- `list_registrations(scope, opts)` — project-scoped, filterable by kind, status, definition_id.
- `upsert_registration(attrs)` — insert or update by config_digest. Notify `trigger_registrations` channel on success.
- `deactivate_registration(registration)` — set status to inactive. Notify channel.
- `record_event(registration_id, event_id, event_data, status)` — insert into trigger_events.

**Supervisor** (`lib/fizz/triggers/supervisor.ex`):

`Fizz.Triggers.Supervisor`:
- Strategy: `:rest_for_one` (Registry must start before pollers).
- Children: `Fizz.Triggers.Registry`.
- Schedule poller and event stream supervisor will be added in Phase 8.

**Config**:

Modify `config/config.exs`:
- Add `triggers: 20` to Oban queues.
- Add `{"* * * * *", Fizz.Triggers.Workers.RegistrationSyncWorker}` to Oban cron plugin.

**Application**:

Modify `lib/fizz/application.ex`:
- Add `Fizz.Triggers.Supervisor` to children list, after `Fizz.Steps.Registry`.

### Tests

`test/fizz/triggers/trigger_registration_test.exs`:
- Schema changeset validates required fields
- Definition-level dedup constraint prevents duplicate `(version_id, step_id)`
- Run-level dedup constraint prevents duplicate `(run_id, step_id)`
- Webhook path unique constraint enforced

`test/fizz/triggers/trigger_event_test.exs`:
- Event dedup constraint on `(registration_id, event_id)`

`test/fizz/triggers/registry_test.exs`:
- Registry loads registrations into ETS on init
- `get_by_webhook_path/1` returns matching registration
- `get_by_webhook_path/1` returns error for unknown path
- `list_by_kind/2` filters by project and kind

`test/fizz/triggers/workers/trigger_fire_worker_test.exs`:
- Definition-level (run_id nil): creates new workflow run with triggered_by metadata
- Run-level (run_id set): delivers signal via signal_run
- Event recorded in trigger_events table

`test/fizz/triggers/workers/registration_sync_worker_test.exs`:
- Creates missing registrations for published versions
- Deactivates registrations for unpublished versions
- Resets errored registrations past cooldown

`test/fizz/triggers/registration_manager_test.exs`:
- `sync_on_publish` creates registrations from trigger manifest
- `sync_on_publish` deactivates previous version registrations
- Idempotent: re-sync with same config produces no duplicates

`test/fizz/workflows/compiler/trigger_manifest_test.exs`:
- Compiler extracts trigger_manifest for workflows with trigger steps
- Compiler rejects trigger steps with incoming connections
- Trigger manifest includes step_id, type_id, config

### Constraints

- All tables include `project_id` and `workos_organization_id`.
- Registration kinds match `Fizz.Triggers.RegistrationSpec`: manual, webhook, schedule, polling, subscription, chat.
- TriggerFireWorker Oban unique constraint: `[:trigger_registration_id, :event_id]`.
- Do NOT implement specific trigger types (webhook routing, schedule polling, etc.) — that's Phase 8.
- Do NOT implement advanced triggers (polling, subscription, chat) — those are future phases.
- The `trigger_manifest` is metadata extracted at compile time. It does NOT affect Runic workflow execution — triggers are assembled as normal Runic steps whose `execute/3` receives normalized input.
- Remember: Ecto `:string` type for both string and text columns. Use `Ecto.Changeset.get_field/2` for changeset field access. Don't use map access on structs.
- Use `start_supervised!/1` in tests for process cleanup.

---

## Phase 8: Basic Triggers (Manual, Webhook, Schedule)

### Specs

- `.spec/specs/workflow-triggers.spec.md` (same spec, different scenarios exercised)

### Goal

Wire up the three basic trigger types — manual, webhook, and schedule — and update existing executor stubs to implement `Fizz.Triggers.Behaviour`. After this phase, workflows can be started by API calls, incoming webhooks, and cron schedules.

### What Already Exists

- Phase 7: `Fizz.Triggers.Behaviour`, `RegistrationSpec`, `TriggerRegistration`, `TriggerEvent`, `Fizz.Triggers.Registry` (ETS), `TriggerFireWorker`, `RegistrationSyncWorker`, `RegistrationManager`, compiler trigger_manifest extraction, publish hook.
- Phase 5: `SignalInbox`, `SignalRouter` for run-level trigger delivery.
- Existing trigger stubs: `manual_input.ex` (passthrough), `schedule_trigger.ex` (interval config), `on_chat_trigger.ex` (minimal).
- Integration trigger stubs: `github_trigger.ex`, `slack_trigger.ex`, `gmail_trigger.ex`, etc. — each has metadata and passthrough `execute/3`.

### Deliverables

**Manual Trigger**:

Modify `lib/fizz/steps/executors/manual_input.ex`:
- Add `@behaviour Fizz.Triggers.Behaviour` (or rely on the `kind: :trigger` macro wire-up from Phase 7).
- Implement `registration_spec/2`: `{:ok, %RegistrationSpec{kind: :manual, params: %{input_schema: config["input_schema"]}}}`. No external infrastructure needed — this is a marker telling the UI this workflow can be manually triggered and what input schema to present.
- Implement `normalize_event/2`: passthrough — `{:ok, raw_event}`.

No new infrastructure needed. The existing `Fizz.Workflows.start_run/3` API already serves as the manual trigger path. The registration is purely a discovery/UI concern.

**Schedule Trigger**:

Modify `lib/fizz/steps/executors/schedule_trigger.ex`:
- Add `@behaviour Fizz.Triggers.Behaviour`.
- Implement `registration_spec/2`:
  ```
  {:ok, %RegistrationSpec{
    kind: :schedule,
    params: %{
      cron: config["cron_expression"],
      interval_seconds: config["interval_seconds"],
      timezone: config["timezone"] || "UTC"
    }
  }}
  ```
- Implement `normalize_event/2`: `{:ok, %{"scheduled_at" => DateTime.to_iso8601(DateTime.utc_now())}}`.
- Update `@config_schema` to add `cron_expression` (string, optional) alongside `interval_seconds`. One of `cron_expression` or `interval_seconds` must be provided.
- Update `validate_config/1` to accept either cron or interval.

`Fizz.Triggers.SchedulePoller` (`lib/fizz/triggers/schedule_poller.ex`) — GenServer:
- Polls every 1 second (configurable).
- Query: `SELECT * FROM trigger_registrations WHERE kind = 'schedule' AND status = 'active' AND next_fire_at <= now() ORDER BY next_fire_at LIMIT 50 FOR UPDATE SKIP LOCKED`. Transition matched rows to `status = 'firing'`.
- For each claimed registration: call `normalize_event/2` on the executor, enqueue `TriggerFireWorker` with the normalized data and a generated `event_id` (e.g., `"sched_#{registration_id}_#{next_fire_at_unix}"`).
- After enqueue: compute next `next_fire_at` from `cron_expression` or `interval_seconds`, update the registration row, reset status to `active`.
- Stale FIRING recovery: same pattern as `TimerPoller` — scan for firing registrations with stale claimed timestamps, reset to active.

Cron expression parsing: add `{:crontab, "~> 1.1"}` to `mix.exs` dependencies. Use `Crontab.CronExpression.Parser.parse/1` and `Crontab.Scheduler.get_next_run_date/2` for computing `next_fire_at`. If `interval_seconds` is used instead of cron, compute `next_fire_at` as `DateTime.add(now, interval_seconds, :second)`.

Add `Fizz.Triggers.SchedulePoller` to `Fizz.Triggers.Supervisor` children (after `Registry`).

**Webhook Trigger**:

`Fizz.Triggers.Webhook` (`lib/fizz/triggers/webhook.ex`):
- `generate_path()` — `"wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)`. Produces unpredictable ~22-char tokens.
- `generate_secret()` — `:crypto.strong_rand_bytes(32) |> Base.encode64()`.
- `verify_signature(payload_body, secret, signature_header_value, algorithm)` — Compute HMAC-SHA256 (or configured algorithm) and compare with timing-safe equality (`Plug.Crypto.secure_compare/2`).

`FizzWeb.Triggers.WebhookController` (`lib/fizz_web/controllers/triggers/webhook_controller.ex`):
- Action `receive(conn, %{"webhook_path" => path})`:
  1. Look up registration via `Fizz.Triggers.Registry.get_by_webhook_path(path)`. Return 404 if not found.
  2. Verify HMAC signature using `Fizz.Triggers.Webhook.verify_signature/4`. Return 401 if invalid.
  3. Read the raw body (must be cached in a Plug for HMAC verification).
  4. Resolve executor via `Fizz.Steps.Executors.Behaviour.resolve!/1`.
  5. Call `executor.match?(registration.registration_params, raw_body_decoded)`. Return 200 (accepted but filtered) if false.
  6. Call `executor.normalize_event(registration.registration_params, raw_body_decoded)`. Return 422 if error.
  7. Generate `event_id` from provider-supplied header (e.g., `X-GitHub-Delivery`) or content hash.
  8. Enqueue `TriggerFireWorker` with `trigger_registration_id`, `event_id`, `normalized_data`.
  9. Return 202 Accepted.

Router (`lib/fizz_web/router.ex`):
- Add a webhook scope OUTSIDE the authenticated browser/API pipelines — webhook endpoints are machine-to-machine and verified by HMAC, not user session:
  ```
  scope "/triggers", FizzWeb.Triggers do
    pipe_through [:api]
    post "/wh/:webhook_path", WebhookController, :receive
  end
  ```
- Ensure the `:api` pipeline is used (JSON parsing, no CSRF). A raw body reader plug must be added to cache the body for HMAC verification (see Plug.Parsers `:body_reader` option).

**Integration Trigger Stubs** (incremental — start with GitHub as reference):

Modify `lib/fizz/steps/executors/github_trigger.ex`:
- Add `@behaviour Fizz.Triggers.Behaviour`.
- Implement `registration_spec/2`: `%RegistrationSpec{kind: :webhook, params: %{events: config["events"], repository: config["repository"]}}`.
- Implement `match?/2`: check incoming event's `X-GitHub-Event` header against configured `events` list.
- Implement `normalize_event/2`: extract relevant fields (action, sender, repository, etc.) from GitHub webhook payload into a clean output map.

Other integration triggers (`slack_trigger`, `gmail_trigger`, `notion_trigger`, etc.) follow the same pattern — add behaviour, implement the three callbacks. These can be done incrementally and are not required for Phase 8 completion. The reference pattern from `github_trigger` is sufficient.

**Webhook Registration in RegistrationManager**:

Modify `lib/fizz/triggers/registration_manager.ex`:
- In `sync_on_publish`, when a trigger's `RegistrationSpec` has `kind: :webhook`: generate `webhook_path` via `Fizz.Triggers.Webhook.generate_path/0` and `webhook_secret` via `Fizz.Triggers.Webhook.generate_secret/0`. Store in the registration row.
- Preserve existing `webhook_path` and `webhook_secret` if a registration already exists for the same step (avoid breaking existing webhook URLs on re-publish).

### Tests

`test/fizz/steps/executors/manual_input_trigger_test.exs`:
- `registration_spec/2` returns `%RegistrationSpec{kind: :manual}`
- `normalize_event/2` passes through input

`test/fizz/steps/executors/schedule_trigger_test.exs`:
- `registration_spec/2` returns `%RegistrationSpec{kind: :schedule}` with cron params
- `normalize_event/2` produces `scheduled_at` timestamp
- `validate_config/1` accepts cron expression or interval_seconds
- `validate_config/1` rejects missing both cron and interval

`test/fizz/triggers/schedule_poller_test.exs`:
- Due schedule registration is claimed and TriggerFireWorker enqueued
- `next_fire_at` is recomputed after fire
- Concurrent pollers claim disjoint registrations (skip locked)
- Stale firing registrations are recovered

`test/fizz_web/controllers/triggers/webhook_controller_test.exs`:
- Valid HMAC → 202 Accepted, TriggerFireWorker enqueued
- Invalid HMAC → 401 Unauthorized
- Unknown webhook_path → 404 Not Found
- `match?` returns false → 200 OK (filtered, no job enqueued)
- `normalize_event` error → 422 Unprocessable Entity

`test/fizz/triggers/webhook_test.exs`:
- Path generation produces unique tokens
- Secret generation produces strong random values
- Signature verification succeeds with correct secret
- Signature verification fails with wrong secret
- Timing-safe comparison used (no early exit)

Integration:
- Publish workflow with schedule trigger → registration created with `next_fire_at` → SchedulePoller fires → TriggerFireWorker creates run → run executes
- Publish workflow with webhook trigger → POST to webhook URL → 202 → TriggerFireWorker creates run → run executes
- Re-publish preserves existing webhook_path (URLs don't break)

### Constraints

- Webhook paths are cryptographically random tokens — NOT sequential, NOT guessable.
- Webhook routes are OUTSIDE authenticated pipelines. The HMAC signature IS the authentication.
- The raw request body must be cached for HMAC verification. Use `Plug.Parsers` `:body_reader` option to capture raw bytes before JSON parsing.
- Rate limiting per-registration is deferred to a future phase.
- Chat trigger (`on_chat_trigger`) is deferred — it requires session management that depends on the LiveView chat UI.
- Advanced patterns (polling, subscription, event stream) are deferred to future phases.
- Integration trigger stubs (github, slack, gmail, etc.) are incremental — start with `github_trigger` as the reference, others follow the same pattern.
- Add `{:crontab, "~> 1.1"}` dependency for cron expression parsing. Run `mix deps.get` after adding.
- Remember: Ecto `:string` type for both string and text columns. Don't nest modules in the same file.
- Use `start_supervised!/1` in tests. Use `Process.monitor/1` + `assert_receive {:DOWN, ...}` instead of `Process.sleep`.
