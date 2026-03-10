# Fizz Accounts Context

`Fizz.Accounts` is the identity and tenancy context for Fizz.

It owns:

- local user records
- organization/workspace authorization scopes
- local workspace and workspace membership persistence
- WorkOS-backed organization identity, auth, and audit integrations
- user-owned external provider auth persistence via `Fizz.Accounts.ExternalAuth` (oauth via pipes, api keys via vault)

## Mental model

Entity hierarchy:

`WorkOS Organization -> Local Workspace -> Local Workspace Membership`

- Organizations are managed in WorkOS (external source of truth).
- Workspaces are local records scoped to a WorkOS organization.
- Workspace memberships are local records that connect users to workspaces.

Authorization is represented by `Fizz.Accounts.Scope`, which carries:

- authenticated user
- active WorkOS organization id
- optional active workspace
- organization role
- workspace role

Most context APIs expect a resolved `%Scope{}`.

## Module map

- `Fizz.Accounts`
  - Main context facade for users, scope building, workspace/member ops, and WorkOS-driven auth/session helpers.
- `Fizz.Accounts.Scope`
  - Authorization carrier and role helper predicates (`organization_admin?/1`, `workspace_admin?/1`, etc.).
- `Fizz.Accounts.ExternalAuth`
  - Account-owned persistence for provider auth state:
    - OAuth connection index (`OauthConnection`)
    - API credential lifecycle and Vault-backed secret resolution (`ApiCredential`)
- `Fizz.Accounts.WorkOS`
  - Facade for WorkOS primitives, split into submodules under `lib/fizz/accounts/workos/`.
- `Fizz.Accounts.WorkOSWebhooks`
  - WorkOS webhook handling entrypoint.
- Schemas:
  - `Fizz.Accounts.User`
  - `Fizz.Accounts.Workspace`
  - `Fizz.Accounts.WorkspaceMembership`
  - `Fizz.Accounts.OauthConnection`
  - `Fizz.Accounts.ApiCredential`

## Responsibility boundaries

- `Fizz.Accounts` is where identity and tenant authorization are resolved.
- `Fizz.Accounts.ExternalAuth` is where provider auth state is stored/retrieved.
- `Fizz.Integrations` orchestrates provider runtime behavior (token fetching, provider modules), but defers auth persistence to `Fizz.Accounts.ExternalAuth`.

## Common flows

### Resolve scope for organization/workspace access

1. Start from `Scope.for_user(user)`.
2. Resolve org/workspace membership via:
   - `Fizz.Accounts.build_scope/3` (organization-first), or
   - `Fizz.Accounts.build_scope_for_workspace/2` (workspace-first).
3. Pass the resolved scope into downstream context calls.

### Workspace management

- Create workspace: `Fizz.Accounts.create_workspace/2`
- List workspaces in active org: `Fizz.Accounts.list_workspaces/1`
- Add/update workspace membership: `Fizz.Accounts.add_workspace_member/4`

### External provider auth persistence

- OAuth connection read/upsert:
  - `Fizz.Accounts.ExternalAuth.get_connection/3`
  - `Fizz.Accounts.ExternalAuth.upsert_oauth_connection/4`
- API credential lifecycle:
  - `Fizz.Accounts.ExternalAuth.list_credentials/2`
  - `Fizz.Accounts.ExternalAuth.create_credential/3`
  - `Fizz.Accounts.ExternalAuth.rotate_credential/4`
  - `Fizz.Accounts.ExternalAuth.delete_credential/3`
  - `Fizz.Accounts.ExternalAuth.resolve_credential_for_use/4`

## WorkOS notes

- WorkOS is the source of truth for organization identity/membership.
- Local user records are synced from WorkOS profile/session flows.
- Widget tokens, Pipes tokens, audit events, and Vault operations are exposed through `Fizz.Accounts.WorkOS` and specialized submodules.

## Error semantics

Context functions generally return:

- `{:ok, value}` on success
- `{:error, reason}` on authorization, validation, or integration failure

Frequent reasons include:

- `:unauthenticated`
- `:forbidden`
- `:workspace_not_found`
- `:organization_scope_required`
- `:credential_not_found`
- `:invalid_provider`

## Development notes

- Keep WorkOS API details isolated under `lib/fizz/accounts/workos/`.
- Keep provider auth persistence in `Fizz.Accounts.ExternalAuth`.
- Keep provider execution/orchestration logic in `Fizz.Integrations`.
- Prefer passing a fully resolved `%Fizz.Accounts.Scope{}` into any operation that depends on tenancy or authorization.

## Read this next

- [lib/fizz/integrations.ex](../integrations.ex)
- [lib/fizz_web/user_auth.ex](../../fizz_web/user_auth.ex)
- [lib/fizz_web/router.ex](../../fizz_web/router.ex)
- [lib/fizz_web/live/workspaces_live/show.ex](../../fizz_web/live/workspaces_live/show.ex)
