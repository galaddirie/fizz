defmodule Fizz.Accounts.WorkOS.Auth do
  @moduledoc """
  WorkOS AuthKit PKCE authorization flow.

  Handles authorization URL generation, code exchange, token refresh, and
  extraction of user profiles and session payloads from authentication responses.
  """

  import Fizz.Accounts.WorkOS.Helpers
  import Fizz.Accounts.WorkOS.Http

  @doc """
  Generates a WorkOS User Management authorization URL (PKCE-only).
  """
  @spec authorization_url(map()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(params) when is_map(params) do
    code_challenge =
      read_value(params, [:code_challenge, "code_challenge", :codeChallenge, "codeChallenge"])

    if is_binary(code_challenge) and byte_size(code_challenge) > 0 do
      redirect_uri =
        read_value(params, [:redirect_uri, "redirect_uri", :redirectUri, "redirectUri"])

      provider = read_value(params, [:provider, "provider"]) || "authkit"

      if is_binary(redirect_uri) and byte_size(redirect_uri) > 0 do
        query =
          compact_map(%{
            provider: provider,
            client_id: WorkOS.client_id(),
            redirect_uri: redirect_uri,
            response_type: "code",
            state: read_value(params, [:state, "state"]),
            organization_id:
              read_value(params, [
                :organization_id,
                "organization_id",
                :organizationId,
                "organizationId"
              ]),
            screen_hint:
              read_value(params, [:screen_hint, "screen_hint", :screenHint, "screenHint"]),
            login_hint: read_value(params, [:login_hint, "login_hint", :loginHint, "loginHint"]),
            domain_hint:
              read_value(params, [:domain_hint, "domain_hint", :domainHint, "domainHint"]),
            code_challenge: code_challenge,
            code_challenge_method:
              read_value(params, [
                :code_challenge_method,
                "code_challenge_method",
                :codeChallengeMethod,
                "codeChallengeMethod"
              ]) || "S256"
          })

        base_url = String.trim_trailing(WorkOS.base_url(), "/")
        {:ok, "#{base_url}/user_management/authorize?#{URI.encode_query(query)}"}
      else
        {:error, :missing_redirect_uri}
      end
    else
      {:error, :missing_code_challenge}
    end
  end

  @doc """
  Authenticates a WorkOS callback authorization code (PKCE-only).
  """
  @spec authenticate_with_code(map()) ::
          {:ok, WorkOS.UserManagement.Authentication.t()} | {:error, term()}
  def authenticate_with_code(params) when is_map(params) do
    code_verifier =
      read_value(params, [:code_verifier, "code_verifier", :codeVerifier, "codeVerifier"])

    if is_binary(code_verifier) and byte_size(code_verifier) > 0 do
      code = read_value(params, [:code, "code"])

      if is_binary(code) and byte_size(code) > 0 do
        body =
          compact_map(%{
            client_id: WorkOS.client_id(),
            client_secret: WorkOS.api_key(),
            grant_type: "authorization_code",
            code: code,
            code_verifier: code_verifier,
            ip_address: read_value(params, [:ip_address, "ip_address", :ipAddress, "ipAddress"]),
            user_agent: read_value(params, [:user_agent, "user_agent", :userAgent, "userAgent"])
          })

        case api_request(:post, "/user_management/authenticate", json: body) do
          {:ok, response} ->
            {:ok, normalize_authentication_response(response)}

          {:error, error} ->
            log_error("authenticate code", error)
            {:error, normalize_error(error)}
        end
      else
        {:error, :missing_authorization_code}
      end
    else
      {:error, :missing_code_verifier}
    end
  end

  @doc """
  Authenticates a WorkOS refresh token and returns a new authentication payload.
  """
  @spec authenticate_with_refresh_token(map()) ::
          {:ok, WorkOS.UserManagement.Authentication.t()} | {:error, term()}
  def authenticate_with_refresh_token(params) when is_map(params) do
    refresh_token =
      read_value(params, [:refresh_token, "refresh_token", :refreshToken, "refreshToken"])

    if is_binary(refresh_token) and byte_size(refresh_token) > 0 do
      body =
        compact_map(%{
          client_id: WorkOS.client_id(),
          client_secret: WorkOS.api_key(),
          grant_type: "refresh_token",
          refresh_token: refresh_token,
          organization_id:
            read_value(params, [
              :organization_id,
              "organization_id",
              :organizationId,
              "organizationId"
            ]),
          ip_address: read_value(params, [:ip_address, "ip_address", :ipAddress, "ipAddress"]),
          user_agent: read_value(params, [:user_agent, "user_agent", :userAgent, "userAgent"])
        })

      case api_request(:post, "/user_management/authenticate", json: body) do
        {:ok, response} ->
          {:ok, normalize_authentication_response(response)}

        {:error, error} ->
          log_error("authenticate refresh token", error)
          {:error, normalize_error(error)}
      end
    else
      {:error, :missing_refresh_token}
    end
  end

  @doc """
  Extracts normalized user profile fields from a WorkOS authentication response.
  """
  @spec extract_user_profile(WorkOS.UserManagement.Authentication.t()) ::
          {:ok, %{id: String.t(), email: String.t(), email_verified: boolean()}}
          | {:error, term()}
  def extract_user_profile(%WorkOS.UserManagement.Authentication{user: user})
      when not is_nil(user) do
    id = read_value(user, ["id", :id])
    email = read_value(user, ["email", :email])

    email_verified =
      read_value(user, ["email_verified", :email_verified, "emailVerified", :emailVerified])

    if is_binary(id) and is_binary(email) do
      {:ok, %{id: id, email: email, email_verified: email_verified in [true, "true"]}}
    else
      {:error, :invalid_workos_user_profile}
    end
  end

  def extract_user_profile(_), do: {:error, :invalid_workos_authentication}

  @doc """
  Extracts WorkOS session fields from an authentication payload.
  """
  @spec extract_session(WorkOS.UserManagement.Authentication.t() | map()) ::
          {:ok,
           %{
             access_token: String.t(),
             refresh_token: String.t(),
             workos_user_id: String.t(),
             session_id: String.t(),
             access_token_expires_at: integer()
           }}
          | {:error, term()}
  def extract_session(authentication) do
    access_token =
      read_value(authentication, [:access_token, "access_token", :accessToken, "accessToken"])

    refresh_token =
      read_value(authentication, [:refresh_token, "refresh_token", :refreshToken, "refreshToken"])

    with true <- is_binary(access_token) and byte_size(access_token) > 0,
         true <- is_binary(refresh_token) and byte_size(refresh_token) > 0,
         {:ok, claims} <- decode_jwt_claims(access_token),
         session_id when is_binary(session_id) <- Map.get(claims, "sid"),
         workos_user_id when is_binary(workos_user_id) <- Map.get(claims, "sub"),
         expires_at when is_integer(expires_at) <- normalize_integer(Map.get(claims, "exp")) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         workos_user_id: workos_user_id,
         session_id: session_id,
         access_token_expires_at: expires_at
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_workos_session}
    end
  end

  defp normalize_authentication_response(
         %WorkOS.UserManagement.Authentication{} = authentication
       ),
       do: authentication

  defp normalize_authentication_response(%{} = response),
    do: WorkOS.UserManagement.Authentication.cast(response)

  defp decode_jwt_claims(access_token) when is_binary(access_token) do
    with [_header, payload, _signature] <- String.split(access_token, ".", parts: 3),
         {:ok, decoded_payload} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded_payload) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_workos_access_token}
    end
  end
end
