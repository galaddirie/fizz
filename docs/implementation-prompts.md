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
- `id` (UUID PK), `run_id` (FK to workflow_runs), `timer_name` (string), `fire_at` (utc_datetime_usec), `status` (string: "pending"/"firing"/"fired"/"cancelled"), `claimed_at` (utc_datetime_usec, nullable), `claimed_by` (string, nullable — node identifier), `created_at` (utc_datetime_usec).
- Indexes: `(status, fire_at)` for polling, `(run_id, status)` for cancellation.

`signal_inbox` table:
- `id` (UUID PK), `run_id` (FK to workflow_runs), `signal_id` (string — caller-provided idempotency key), `signal_name` (string), `payload` (jsonb), `delivered` (boolean, default false), `created_at` (utc_datetime_usec).
- Unique index on `(run_id, signal_id)` for dedup.
- Index on `(run_id, delivered)` for delivery scan.

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
- The exact mechanism: define a step output convention (e.g., `{:timer, %{fire_at: datetime}}`) that the Worker's dispatch loop recognizes and persists.

Timer cancellation in `Fizz.Workflows.cancel_run/2`:
- `UPDATE durable_timers SET status = 'cancelled' WHERE run_id = ? AND status = 'pending'`.

**Signal Delivery**:

`Fizz.Workflows.Signal` (Ecto schema):
- Standard schema for the `signal_inbox` table.

`Fizz.Workflows.SignalRouter`:
- `accept_signal(run_id, signal_id, signal_name, payload)` — Insert into inbox with `ON CONFLICT (run_id, signal_id) DO NOTHING` for idempotent acceptance. Signal is always accepted into inbox regardless of run status.
- After insert, attempt delivery: if run is active (Worker alive), deliver directly via `Runner.Worker.deliver_event/2`. If dormant, trigger wake-up (acquire lease, start Worker, deliver).
- If run is terminal, signal is recorded but delivery is skipped.
- Ordering: delivery order is NOT guaranteed to match submission order.

Optionally implement LISTEN/NOTIFY as a latency optimization — but polling catch-up is the authoritative path. For v1, polling-only is acceptable.

**Worker Integration**:
- Add `deliver_event(pid, event)` to Worker — accepts timer fires and signals, feeds them into the Runic workflow as new input facts.
- After delivering a signal, mark it as `delivered = true` in the inbox.

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
