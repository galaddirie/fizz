defmodule Fizz.Integrations.WorkOSClient do
  @moduledoc """
  Behaviour for app-facing WorkOS operations.
  """

  alias Fizz.Accounts.User

  @callback ensure_user(User.t()) :: {:ok, String.t()} | {:error, term()}

  @callback ensure_organization_membership(String.t(), User.t(), atom() | String.t() | nil) ::
              {:ok, %{user_id: String.t() | nil, membership_id: String.t() | nil}}
              | {:error, term()}

  @callback create_audit_event(String.t(), User.t(), String.t(), [map()], map()) ::
              :ok | {:error, term()}

  @callback authorization_url(map()) :: {:ok, String.t()} | {:error, term()}

  @callback authenticate_with_code(map()) ::
              {:ok, WorkOS.UserManagement.Authentication.t()} | {:error, term()}

  @callback authenticate_with_refresh_token(map()) ::
              {:ok, WorkOS.UserManagement.Authentication.t()} | {:error, term()}

  @callback extract_user_profile(WorkOS.UserManagement.Authentication.t()) ::
              {:ok, %{id: String.t(), email: String.t(), email_verified: boolean()}}
              | {:error, term()}

  @callback extract_session(WorkOS.UserManagement.Authentication.t() | map()) ::
              {:ok,
               %{
                 access_token: String.t(),
                 refresh_token: String.t(),
                 workos_user_id: String.t(),
                 session_id: String.t(),
                 access_token_expires_at: integer()
               }}
              | {:error, term()}

  @callback list_user_organization_memberships(String.t()) :: {:ok, [map()]} | {:error, term()}

  @callback get_user_organization_membership(String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback user_has_organization_membership?(String.t(), String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @callback generate_widget_token(map()) :: {:ok, String.t()} | {:error, term()}

  @callback get_pipes_access_token(String.t(), String.t(), String.t() | nil) ::
              {:ok, map()} | {:error, term()}

  @callback create_vault_object(map()) :: {:ok, map()} | {:error, term()}

  @callback delete_vault_object(String.t()) :: :ok | {:error, term()}
end
