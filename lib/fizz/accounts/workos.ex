defmodule Fizz.Accounts.WorkOS do
  @moduledoc """
  Accounts-facing facade over WorkOS API primitives.

  Delegates to specialized submodules:

  * `WorkOS.Auth` — AuthKit PKCE authorization flow
  * `WorkOS.Memberships` — organization membership sync
  * `WorkOS.Organizations` — organization CRUD
  * `WorkOS.Api` — audit events, widget tokens, Pipes access tokens, Vault objects
  * `WorkOS.Http` — low-level authenticated HTTP client

  Sync is disabled by default and can be enabled via:

      config :fizz, :workos_sync_enabled, true

  The HTTP client and WorkOS SDK modules are configurable for testing:

      config :fizz, :workos_http_client_module, MyMockReq
      config :fizz, :workos_user_management_module, MyMockUserManagement
      config :fizz, :workos_audit_logs_module, MyMockAuditLogs
  """

  # Organizations
  defdelegate create_workos_organization(name, opts \\ []),
    to: __MODULE__.Organizations,
    as: :create_organization

  defdelegate get_workos_organization(org_id), to: __MODULE__.Organizations, as: :get_organization

  defdelegate update_workos_organization(org_id, attrs),
    to: __MODULE__.Organizations,
    as: :update_organization

  # Memberships
  defdelegate enabled?, to: __MODULE__.Memberships
  defdelegate ensure_user(user), to: __MODULE__.Memberships

  defdelegate ensure_organization_membership(org_id, user, role \\ :member),
    to: __MODULE__.Memberships

  defdelegate create_organization_membership(user_id, org_id, role \\ nil),
    to: __MODULE__.Memberships

  defdelegate list_user_organization_memberships(workos_user_id), to: __MODULE__.Memberships
  defdelegate get_user_organization_membership(workos_user_id, org_id), to: __MODULE__.Memberships

  defdelegate user_has_organization_membership?(workos_user_id, org_id),
    to: __MODULE__.Memberships

  # Auth
  defdelegate generate_code_verifier(bytes \\ 32), to: __MODULE__.Auth
  defdelegate code_challenge_s256(code_verifier), to: __MODULE__.Auth
  defdelegate authorization_url(params), to: __MODULE__.Auth
  defdelegate authenticate_with_code(params), to: __MODULE__.Auth
  defdelegate authenticate_with_refresh_token(params), to: __MODULE__.Auth
  defdelegate extract_user_profile(authentication), to: __MODULE__.Auth
  defdelegate extract_session(authentication), to: __MODULE__.Auth

  # API (audit, widgets, pipes, vault)
  defdelegate create_audit_event(org_id, actor, action, targets, context), to: __MODULE__.Api
  defdelegate generate_widget_token(params), to: __MODULE__.Api
  defdelegate get_pipes_access_token(provider, user_id, org_id \\ nil), to: __MODULE__.Api
  defdelegate create_vault_object(params), to: __MODULE__.Api
  defdelegate read_vault_object(object_id), to: __MODULE__.Api
  defdelegate read_vault_object_by_name(name, opts \\ %{}), to: __MODULE__.Api
  defdelegate list_vault_objects(query \\ %{}), to: __MODULE__.Api
  defdelegate update_vault_object(object_id, params), to: __MODULE__.Api
  defdelegate delete_vault_object(object_id, params \\ %{}), to: __MODULE__.Api
end
