## Steps Library & Integrations

This document describes the step type system, executor behaviour, and integration provider architecture in Fizz. It covers how step types are defined, registered, configured, and executed, as well as how external integrations surface as credentials and providers.

---

### Design Goals

- Step types are **compile-time artefacts**, not database rows. The registry is an in-memory ETS table populated at startup from a fixed set of executor modules.
- Step metadata (id, name, category, icon, kind) is validated at compile time via a macro — invalid definitions fail the build, not runtime.
- Config schemas are **JSON Schema** documents extended with optional `"ui"` hints for the editor (component type, resolver, response mapping). They drive both validation and UI rendering with a single source of truth.
- **Credentials never flow through the step config.** Credential refs carry only metadata (provider, auth_type, display_name, owner). Secrets stay in the external vault (WorkOS/Vault). The step executor fetches a live token at runtime via the provider behaviour.
- The **subnode pattern** allows complex composite steps (e.g. AI agent) to accept typed child nodes (model config, prompt template, tools) without baking composition logic into the parent.

---

### Core Concepts

#### Step Kind

Every step type declares a `kind` that determines its role in the execution graph:

| Kind | Description |
|---|---|
| `:trigger` | Starts a workflow run. Only one trigger is allowed per graph root. |
| `:action` | Performs a side-effectful operation (HTTP call, send email, etc.). |
| `:transform` | Reshapes data without side effects (format, parse, filter). |
| `:control_flow` | Branches or merges execution paths (condition, switch, join). |

#### Step Role

Steps also carry an optional **role** for hierarchical composition:

| Role | Description |
|---|---|
| `nil` (default) | Standalone node — placed directly in the workflow graph. |
| `:root` | Accepts subnodes via declared inputs (e.g. `ai_agent`). |
| `:subnode` | Feeds a root node's typed input, not as a top-level graph node (e.g. `openai_model`, `ai_prompt_template`). |

---

### Step Definition

Every step type is an Elixir module that calls `use Fizz.Steps.Definition` with its metadata:

```elixir
defmodule Fizz.Steps.Executors.Format do
  use Fizz.Steps.Definition,
    id: "format",
    name: "Format Text",
    category: "Transform",
    description: "Interpolates a template string using step input fields.",
    icon: "hero-document-text",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "template" => %{"type" => "string", "title" => "Template"}
    },
    "required" => ["template"]
  }
end
```

The macro:

1. Validates that all required fields (`id`, `name`, `category`, `description`, `icon`, `kind`) are present at compile time — a missing field raises a `CompileError`.
2. Injects `__step_id__/0`, `__step_definition__/0`, and `default_config/0` functions into the module.
3. Collects optional module attributes (`@config_schema`, `@input_schema`, `@output_schema`, `@subnode_inputs`) into the definition struct.

#### Config Schema

Config schemas are JSON Schema objects optionally extended with a `"ui"` key per property:

```elixir
@config_schema %{
  "type" => "object",
  "properties" => %{
    "credential" => %{
      "type" => "object",
      "title" => "GitHub Credential",
      "ui" => %{
        "component" => "search_select",
        "resolver" => "Elixir.Fizz.Integrations.CredentialsResolver",
        "resolver_params" => %{"provider_filter" => "github"},
        "response_map" => %{"label" => "display_name", "value" => "id"}
      }
    }
  }
}
```

The `"ui"` extension is never passed to a JSON Schema validator — it is only consumed by the editor frontend to render the correct input component (e.g. a searchable credential picker vs. a plain text input).

#### Subnode Inputs

Root nodes declare inputs to describe what subnodes they accept:

```elixir
@subnode_inputs [
  %{key: "model", label: "Model", required: true, cardinality: :one,
    allowed_types: ["openai_model", "anthropic_model"]},
  %{key: "prompt", label: "Prompt", required: true, cardinality: :one,
    allowed_types: ["ai_prompt_template"]},
  %{key: "tools", label: "Tools", required: false, cardinality: :many,
    allowed_types: ["ai_tool_http"]}
]
```

At execution time the root executor receives subnode configs pre-resolved and keyed by input name. Subnodes are never executed independently.

---

### Step Type Struct

`Fizz.Steps.Type` is the read-only struct exposed to callers outside the executor layer:

```
%Fizz.Steps.Type{
  id:             "openai_model",        # unique string identifier
  name:           "OpenAI Model",        # display name
  category:       "AI",                  # grouping label
  description:    "...",
  icon:           "hero-cpu-chip",
  step_kind:      :action,               # :trigger | :action | :transform | :control_flow
  role:           :subnode,              # nil | :root | :subnode
  config_schema:  %{...},               # JSON Schema + ui extensions
  input_schema:   %{...},               # expected input shape
  output_schema:  %{...},               # produced output shape
  subnode_inputs:  [...],                 # input declarations (root nodes only)
  executor:       Fizz.Steps.Executors.OpenaiModel
}
```

Helper predicates: `Type.trigger?/1`, `Type.action?/1`, `Type.transform?/1`, `Type.control_flow?/1`.

---

### Registry

`Fizz.Steps.Registry` owns an ETS table (`fizz_step_types`) created at application start. It auto-discovers all executor modules via `@executor_modules` — a hardcoded list of 55 modules that is the single place to add new step types.

Key functions:

| Function | Description |
|---|---|
| `all/0` | Returns all registered `Type` structs. |
| `get/1` | Looks up a type by string id. |
| `by_category/1` | Filters by category string. |
| `by_kind/1` | Filters by step kind atom. |
| `grouped_by_category/0` | Returns `%{category => [Type]}` map for sidebar rendering. |
| `library_items/0` | Returns lightweight maps for the node editor drag palette. |

The module name convention is `Fizz.Steps.Executors.<PascalCase>` where `PascalCase` is derived from the step id string (e.g. `"ai_agent"` → `AiAgent`). `Type.executor_module/1` performs this conversion.

---

### Executor Behaviour

`Fizz.Steps.Executors.Behaviour` defines the contract every executor implements:

```elixir
@callback execute(config :: map(), input :: map(), context :: map()) ::
  {:ok, output :: map()} | {:error, reason :: term()} | {:skip, reason :: term()}
```

Optional callbacks:

```elixir
@callback validate_config(config :: map()) :: :ok | {:error, errors :: list()}
@callback default_config() :: map()
@callback effective_output_schema(config :: map()) :: map()
```

`execute/3` receives:
- **config** — the step's persisted configuration (validated against `config_schema`)
- **input** — the resolved input from upstream steps
- **context** — runtime context including `user_id`, `workflow_run_id`, credential store, etc.

Return values:
- `{:ok, output}` — step succeeded; `output` is passed downstream
- `{:error, reason}` — step failed; the run engine decides retry/halt policy
- `{:skip, reason}` — step was intentionally skipped (e.g. condition branch not taken)

The behaviour module also provides a `resolver/1` convenience that instantiates resolver modules by atom or string name.

---

### Integrations

#### Provider Behaviour

`Fizz.Integrations.Provider` is the interface for external OAuth and API-key providers:

```elixir
@callback provider_id() :: String.t()
@callback display_name() :: String.t()
@callback check_connection(credential_ref :: map(), context :: map()) ::
  {:ok, connection_status()} | {:error, term()}
@callback fetch_token(credential_ref :: map(), context :: map()) ::
  {:ok, token_result()} | {:error, term()}
@callback network_domains() :: [String.t()]
```

Optional callbacks:

```elixir
@callback list_repos(credential_ref :: map(), opts :: keyword()) ::
  {:ok, [map()]} | {:error, term()}
@callback create_pull_request(credential_ref :: map(), params :: map()) ::
  {:ok, map()} | {:error, term()}
```

`fetch_token/2` always returns a live, non-expired token. Implementors handle refresh internally (WorkOS Pipes for OAuth, Vault for API keys).

**Resume safety:** The credential resolver closure (which calls `fetch_token/2`) is injected into the workflow's `run_context` at start time. On workflow resume from checkpoint, this closure must be **reconstructed** from durable metadata (Postgres `workflow_runs` row), not deserialized from the checkpoint. The closure captures `scope`, which may contain process-bound references that don't survive serialization. See the compiler design doc's "Known Gaps" section and the durable platform design doc for the full contract.

`connection_status` carries structured connection health:

```elixir
%{
  active: boolean(),
  scopes: [String.t()],        # granted OAuth scopes
  missing_scopes: [String.t()], # required but absent scopes
  metadata: map(),              # provider-specific (avatar, username, etc.)
  error: String.t() | nil
}
```

#### Provider Catalog

`Fizz.Integrations.ProviderCatalog` is the authoritative registry of available providers. Providers are keyed by a compound id of the form `"<base>_<auth_type>"` (e.g. `"github_oauth"`, `"openai_api_key"`).
Built-in metadata lives with the provider definition modules; the catalog only
assembles those definitions and enforces typed provider IDs.

Built-in providers:

| Provider ID | Auth Type | Module |
|---|---|---|
| `github_oauth` | oauth | `Fizz.Integrations.Providers.GitHubOAuth` |
| `github_api_key` | api_key | `Fizz.Integrations.Providers.GitHubApiKey` |
| `openai_api_key` | api_key | `Fizz.Integrations.Providers.OpenAIApiKey` |
| `anthropic_api_key` | api_key | `Fizz.Integrations.Providers.AnthropicApiKey` |
| `slack_oauth` | oauth | `Fizz.Integrations.Providers.SlackOAuth` |
| `google_oauth` | oauth | `Fizz.Integrations.Providers.GoogleOAuth` |
| `microsoft_oauth` | oauth | `Fizz.Integrations.Providers.MicrosoftOAuth` |
| `notion_oauth` | oauth | `Fizz.Integrations.Providers.NotionOAuth` |
| `box_oauth` | oauth | `Fizz.Integrations.Providers.BoxOAuth` |
| `custom_api_key` | api_key | `Fizz.Integrations.Providers.CustomApiKey` |

#### Credential Refs

A credential ref is a **metadata-only** map that travels with a workflow config. It never contains secrets:

```elixir
%{
  id: "cred-uuid",
  provider: "github_oauth",
  auth_type: "oauth",
  display_name: "My GitHub",
  owner_user_id: "user-uuid"
}
```

`Fizz.Integrations.CredentialRef` provides:
- `normalize/1` — coerces atom/string keys, fills defaults
- `valid?/1` — checks required fields present
- `matches_provider?/2` — verifies provider + auth_type match a provider id string

#### Credentials Resolver

`Fizz.Integrations.CredentialsResolver` implements `Fizz.Steps.Resolver` and is used as the `"resolver"` in config schema `"ui"` extensions. It:

1. Fetches all `ExternalAuth` records for the current user.
2. Filters by `provider_filter` and `auth_types` params from the schema.
3. Applies optional text search across `display_name`, `provider_label`, and `auth_type`.
4. Returns up to 50 results shaped for the `search_select` component.

---

### Current Executor Inventory

#### Triggers
`manual_input`, `schedule_trigger`, `on_chat_trigger`

#### Control Flow
`condition`, `switch`, `join`

#### Transform
`format`, `json_parser`, `data_filter`, `data_transform`, `math`, `debug`

#### Collection
`splitter`, `aggregator`

#### Utility
`http_request`, `wait`, `data_output`

#### AI
`ai_agent` _(root)_, `ai_prompt_template` _(subnode)_, `ai_tool_http` _(subnode)_, `openai_model` _(subnode)_, `anthropic_model` _(subnode)_, `openai_structured_output`, `openai_image_generation`, `anthropic_vision_analysis`

#### Integration Stubs (not yet implemented)
Gmail (`gmail_trigger`, `gmail_send_email`, `gmail_reply_email`), Slack (`slack_trigger`, `slack_send_message`, `slack_create_channel`), Google Docs/Sheets/Slides, Google Drive, OneDrive, SharePoint, Notion, GitHub (`github_trigger`, `github_create_issue`, `github_create_pr`), Outlook, Teams, PowerPoint, Box.

---

### Key Files

| Path | Purpose |
|---|---|
| `lib/fizz/steps/definition.ex` | `use Fizz.Steps.Definition` macro |
| `lib/fizz/steps/type.ex` | `Fizz.Steps.Type` struct + helpers |
| `lib/fizz/steps/registry.ex` | ETS-backed step type registry |
| `lib/fizz/steps/config_schema.ex` | Config schema typespecs |
| `lib/fizz/steps/resolver.ex` | Resolver behaviour |
| `lib/fizz/steps/executors/behaviour.ex` | Executor behaviour |
| `lib/fizz/steps/executors/` | All 55+ executor modules |
| `lib/fizz/integrations/provider.ex` | Provider behaviour |
| `lib/fizz/integrations/provider_catalog.ex` | Provider registry |
| `lib/fizz/integrations/credential_ref.ex` | Credential ref helpers |
| `lib/fizz/integrations/credentials_resolver.ex` | Credential search resolver |
| `lib/fizz/integrations/providers/github_oauth.ex` | GitHub OAuth provider |
| `lib/fizz/integrations/providers/openai_api_key.ex` | OpenAI API key provider |
