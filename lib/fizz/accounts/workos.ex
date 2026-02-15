defmodule Fizz.Accounts.WorkOS do
  @moduledoc """
  Accounts-facing wrapper over WorkOS primitives.

  Sync is disabled by default and can be enabled via:

      config :fizz, :workos_sync_enabled, true
  """

  # Memberships
  defdelegate enabled?, to: __MODULE__.Memberships
  defdelegate ensure_user(user), to: __MODULE__.Memberships
  defdelegate ensure_organization_membership(org_id, user, role \\ :member), to: __MODULE__.Memberships
  defdelegate create_organization_membership(user_id, org_id, role \\ nil), to: __MODULE__.Memberships
  defdelegate list_user_organization_memberships(workos_user_id), to: __MODULE__.Memberships
  defdelegate get_user_organization_membership(workos_user_id, org_id), to: __MODULE__.Memberships
  defdelegate user_has_organization_membership?(workos_user_id, org_id), to: __MODULE__.Memberships

  # Auth
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
  defdelegate delete_vault_object(object_id), to: __MODULE__.Api
end
