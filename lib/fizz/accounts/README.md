# Fizz Accounts Context

`Fizz.Accounts` is the identity and tenancy context for Fizz.

It owns:

- local user records
- organization/project authorization scopes
- local project and project membership persistence
- WorkOS-backed organization identity, auth, and audit integrations
- user-owned external provider auth persistence via `Fizz.Accounts.ExternalAuth` (ouath via pipes, api keys via vault)

## Mental model

Entity hierarchy:

`WorkOS Organization -> Local Project -> Local Project Membership`

- Organizations are managed in WorkOS (external source of truth).
- Projects are local records scoped to a WorkOS organization.
- Project memberships are local records that connect users to projects.

Authorization is represented by `Fizz.Accounts.Scope`, which carries:

- authenticated user
- active WorkOS organization id
- optional active project
- organization role
- project role

Most context APIs expect a resolved `%Scope{}`.

## Module map

- `Fizz.Accounts`
  - Main context facade for users, scope building, project/member ops, and WorkOS-driven auth/session helpers.
- `Fizz.Accounts.Scope`
  - Authorization carrier and role helper predicates (`organization_admin?/1`, `project_admin?/1`, etc.).
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
  - `Fizz.Accounts.Project`
  - `Fizz.Accounts.ProjectMembership`
  - `Fizz.Accounts.OauthConnection`
  - `Fizz.Accounts.ApiCredential`

## Responsibility boundaries

- `Fizz.Accounts` is where identity and tenant authorization are resolved.
- `Fizz.Accounts.ExternalAuth` is where provider auth state is stored/retrieved.
- `Fizz.Integrations` orchestrates provider runtime behavior (token fetching, provider modules), but defers auth persistence to `Fizz.Accounts.ExternalAuth`.

## Common flows

### Resolve scope for organization/project access

1. Start from `Scope.for_user(user)`.
2. Resolve org/project membership via:
   - `Fizz.Accounts.build_scope/3` (organization-first), or
   - `Fizz.Accounts.build_scope_for_project/2` (project-first).
3. Pass the resolved scope into downstream context calls.

### Project management

- Create project: `Fizz.Accounts.create_project/2`
- List projects in active org: `Fizz.Accounts.list_projects/1`
- Add/update project membership: `Fizz.Accounts.add_project_member/4`

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
- `:project_not_found`
- `:organization_scope_required`
- `:credential_not_found`
- `:invalid_provider`

## Development notes

- Keep WorkOS API details isolated under `lib/fizz/accounts/workos/`.
- Keep provider auth persistence in `Fizz.Accounts.ExternalAuth`.
- Keep provider execution/orchestration logic in `Fizz.Integrations`.
- Prefer passing a fully resolved `%Fizz.Accounts.Scope{}` into any operation that depends on tenancy or authorization.
