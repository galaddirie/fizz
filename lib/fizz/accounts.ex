defmodule Fizz.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  alias Fizz.Accounts.{Identity, User, UserToken, WorkOS}
  alias Fizz.Repo

  ## Identity & Tenancy

  defdelegate list_tenants(scope), to: Identity
  defdelegate create_tenant(scope, attrs, opts \\ []), to: Identity
  defdelegate build_scope(scope, tenant_id, opts \\ []), to: Identity
  defdelegate list_workspaces(scope), to: Identity
  defdelegate create_workspace(scope, attrs), to: Identity
  defdelegate add_tenant_member(scope, user, attrs), to: Identity
  defdelegate add_workspace_member(scope, workspace_id, user, attrs), to: Identity
  defdelegate sync_user_to_workos(scope), to: Identity
  defdelegate workos_authorization_url(params), to: WorkOS, as: :authorization_url

  ## Users

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by WorkOS user id.
  """
  def get_user_by_workos_user_id(workos_user_id) when is_binary(workos_user_id) do
    Repo.get_by(User, workos_user_id: workos_user_id)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Exchanges a WorkOS AuthKit code and returns/logically provisions the local user.
  """
  def authenticate_user_with_workos_code(code, opts \\ %{}) when is_binary(code) do
    with {:ok, %{user: user}} <- authenticate_user_with_workos_code_and_session(code, opts) do
      {:ok, user}
    end
  end

  @doc """
  Exchanges a WorkOS AuthKit code and returns the local user plus WorkOS session id.
  """
  def authenticate_user_with_workos_code_and_session(code, opts \\ %{}) when is_binary(code) do
    auth_params = %{
      code: code,
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    }

    with {:ok, authentication} <- WorkOS.authenticate_with_code(auth_params),
         {:ok, profile} <- WorkOS.extract_user_profile(authentication),
         {:ok, user} <- get_or_upsert_user_from_workos_profile(profile) do
      {:ok, %{user: user, workos_session_id: extract_workos_session_id(authentication)}}
    end
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the signed session token.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token]))
    :ok
  end

  ## WorkOS profile sync

  defp get_or_upsert_user_from_workos_profile(%{id: workos_user_id, email: email} = profile) do
    case get_user_by_workos_user_id(workos_user_id) do
      %User{} = user ->
        update_user_from_workos_profile(user, profile)

      nil ->
        case get_user_by_email(email) do
          %User{workos_user_id: nil} = user ->
            update_user_from_workos_profile(user, profile)

          %User{workos_user_id: ^workos_user_id} = user ->
            update_user_from_workos_profile(user, profile)

          %User{} ->
            {:error, :workos_account_conflict}

          nil ->
            register_user_from_workos_profile(profile)
        end
    end
  end

  defp register_user_from_workos_profile(%{
         id: workos_user_id,
         email: email,
         email_verified: verified
       }) do
    confirmed_at = if verified, do: DateTime.utc_now(:second), else: nil

    %User{}
    |> User.workos_profile_changeset(%{
      email: email,
      workos_user_id: workos_user_id,
      confirmed_at: confirmed_at
    })
    |> Repo.insert()
  end

  defp update_user_from_workos_profile(
         %User{} = user,
         %{id: workos_user_id, email: email, email_verified: verified}
       ) do
    confirmed_at =
      if verified, do: user.confirmed_at || DateTime.utc_now(:second), else: user.confirmed_at

    user
    |> User.workos_profile_changeset(%{
      email: email,
      workos_user_id: workos_user_id,
      confirmed_at: confirmed_at
    })
    |> Repo.update()
  end

  defp extract_workos_session_id(%Elixir.WorkOS.UserManagement.Authentication{
         access_token: access_token
       })
       when is_binary(access_token) do
    with [_header, payload, _signature] <- String.split(access_token, ".", parts: 3),
         {:ok, decoded_payload} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded_payload),
         sid when is_binary(sid) <- claims["sid"] do
      sid
    else
      _ -> nil
    end
  end

  defp extract_workos_session_id(_), do: nil
end
