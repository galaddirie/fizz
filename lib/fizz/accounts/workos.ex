defmodule Fizz.Accounts.WorkOS do
  @moduledoc """
  Accounts-facing wrapper over WorkOS primitives.

  Sync is disabled by default and can be enabled via:

      config :fizz, :workos_sync_enabled, true
  """

  require Logger

  alias Fizz.Accounts.{Organization, User}

  @doc """
  Returns whether WorkOS sync is enabled.
  """
  def enabled?, do: Application.get_env(:fizz, :workos_sync_enabled, false)

  @doc """
  Creates and links WorkOS organization/user/membership for a organization owner.
  """
  @spec sync_organization_and_owner(%Organization{}, %User{}, atom() | String.t() | nil) ::
          {:ok,
           %{
             organization_id: String.t() | nil,
             user_id: String.t() | nil,
             membership_id: String.t() | nil
           }}
          | {:error, term()}
  def sync_organization_and_owner(%Organization{} = organization, %User{} = user, role \\ :owner) do
    if enabled?() do
      with {:ok, workos_user_id} <- ensure_user(user),
           {:ok, organization_id} <- ensure_organization(organization),
           {:ok, membership_id} <-
             find_or_create_organization_membership(workos_user_id, organization_id, role) do
        {:ok,
         %{
           organization_id: organization_id,
           user_id: workos_user_id,
           membership_id: membership_id
         }}
      end
    else
      {:ok, %{organization_id: nil, user_id: user.workos_user_id, membership_id: nil}}
    end
  end

  @doc """
  Ensures a local user has a WorkOS user record.
  """
  @spec ensure_user(%User{}) :: {:ok, String.t()} | {:error, term()}
  def ensure_user(%User{workos_user_id: workos_user_id}) when is_binary(workos_user_id) do
    {:ok, workos_user_id}
  end

  def ensure_user(%User{} = user) do
    with {:ok, created_user} <-
           user_management_module().create_user(%{
             email: user.email,
             external_id: to_string(user.id),
             email_verified: not is_nil(user.confirmed_at)
           }) do
      {:ok, created_user.id}
    else
      {:error, error} ->
        log_error("create user", error)
        {:error, normalize_error(error)}
    end
  rescue
    error in RuntimeError ->
      Logger.error("WorkOS configuration error when creating user: #{Exception.message(error)}")
      {:error, :workos_not_configured}
  end

  @doc """
  Ensures a user has organization membership in WorkOS for the given organization.
  """
  @spec ensure_organization_membership(%Organization{}, %User{}, atom() | String.t() | nil) ::
          {:ok, %{user_id: String.t() | nil, membership_id: String.t() | nil}} | {:error, term()}
  def ensure_organization_membership(organization, user, role \\ :member)

  def ensure_organization_membership(
        %Organization{workos_organization_id: workos_organization_id},
        %User{} = user,
        role
      )
      when is_binary(workos_organization_id) do
    if enabled?() do
      with {:ok, workos_user_id} <- ensure_user(user),
           {:ok, membership_id} <-
             find_or_create_organization_membership(workos_user_id, workos_organization_id, role) do
        {:ok, %{user_id: workos_user_id, membership_id: membership_id}}
      end
    else
      {:ok, %{user_id: user.workos_user_id, membership_id: nil}}
    end
  end

  def ensure_organization_membership(%Organization{}, %User{} = user, _role) do
    if enabled?() do
      {:error, :missing_workos_organization_id}
    else
      {:ok, %{user_id: user.workos_user_id, membership_id: nil}}
    end
  end

  @doc """
  Creates a WorkOS organization for a organization.
  """
  @spec create_organization(%Organization{}) ::
          {:ok, WorkOS.Organizations.Organization.t()} | {:error, term()}
  def create_organization(%Organization{} = organization) do
    options = %{
      name: organization.name,
      idempotency_key: "organization-#{organization.slug}"
    }

    case organizations_module().create_organization(options) do
      {:ok, organization} ->
        {:ok, organization}

      {:error, error} ->
        log_error("create organization", error)
        {:error, normalize_error(error)}
    end
  rescue
    error in RuntimeError ->
      Logger.error(
        "WorkOS configuration error when creating organization: #{Exception.message(error)}"
      )

      {:error, :workos_not_configured}
  end

  @doc """
  Creates a WorkOS organization membership.
  """
  @spec create_organization_membership(String.t(), String.t(), atom() | String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def create_organization_membership(workos_user_id, workos_organization_id, role \\ nil)
      when is_binary(workos_user_id) and is_binary(workos_organization_id) do
    body =
      compact_map(%{
        user_id: workos_user_id,
        organization_id: workos_organization_id,
        role_slug: role_slug_for(role)
      })

    case api_request(:post, "/user_management/organization_memberships", json: body) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, error} ->
        log_error("create organization membership", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Emits an audit event to WorkOS for a organization organization.
  """
  @spec create_audit_event(%Organization{}, %User{}, String.t(), [map()], map()) ::
          :ok | {:error, term()}
  def create_audit_event(
        %Organization{workos_organization_id: workos_organization_id},
        %User{} = actor,
        action,
        targets,
        context
      )
      when is_binary(workos_organization_id) and is_binary(action) do
    if enabled?() do
      event = %{
        action: action,
        actor: %{
          type: "user",
          id: actor.workos_user_id || to_string(actor.id)
        },
        occurred_at: DateTime.utc_now(:second) |> DateTime.to_iso8601(),
        targets: normalize_targets(targets),
        context: Map.new(context)
      }

      case audit_logs_module().create_event(%{
             organization_id: workos_organization_id,
             event: event
           }) do
        {:ok, _response} ->
          :ok

        {:error, error} ->
          log_error("create audit event", error)
          {:error, normalize_error(error)}
      end
    else
      :ok
    end
  rescue
    error in RuntimeError ->
      Logger.error(
        "WorkOS configuration error when creating audit event: #{Exception.message(error)}"
      )

      {:error, :workos_not_configured}
  end

  def create_audit_event(_organization, _actor, _action, _targets, _context), do: :ok

  @doc """
  Generates a WorkOS User Management authorization URL.
  """
  @spec authorization_url(map()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(params) when is_map(params) do
    user_management_module().get_authorization_url(params)
  rescue
    error in RuntimeError ->
      Logger.error(
        "WorkOS configuration error when generating authorization URL: #{Exception.message(error)}"
      )

      {:error, :workos_not_configured}
  end

  @doc """
  Authenticates a WorkOS callback authorization code.
  """
  @spec authenticate_with_code(map()) ::
          {:ok, WorkOS.UserManagement.Authentication.t()} | {:error, term()}
  def authenticate_with_code(params) when is_map(params) do
    user_management_module().authenticate_with_code(params)
  rescue
    error in RuntimeError ->
      Logger.error(
        "WorkOS configuration error when authenticating code: #{Exception.message(error)}"
      )

      {:error, :workos_not_configured}
  end

  @doc """
  Generates a WorkOS widget token.
  """
  @spec generate_widget_token(map()) :: {:ok, String.t()} | {:error, term()}
  def generate_widget_token(params) when is_map(params) do
    body =
      compact_map(%{
        organization_id:
          read_value(params, [
            :organization_id,
            "organization_id",
            :organizationId,
            "organizationId"
          ]),
        user_id: read_value(params, [:user_id, "user_id", :userId, "userId"]),
        scopes: normalize_widget_scopes(read_value(params, [:scopes, "scopes"]))
      })

    case api_request(:post, "/widgets/token", json: body) do
      {:ok, response} ->
        case read_value(response, [:token, "token"]) do
          token when is_binary(token) ->
            {:ok, token}

          _ ->
            {:error, :invalid_widget_token_response}
        end

      {:error, error} ->
        log_error("generate widget token", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Fetches an access token for a Pipes provider connection.
  """
  @spec get_pipes_access_token(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def get_pipes_access_token(provider, user_id, organization_id \\ nil)
      when is_binary(provider) and is_binary(user_id) do
    path = "/data-integrations/#{URI.encode_www_form(provider)}/token"
    body = compact_map(%{user_id: user_id, organization_id: organization_id})

    case api_request(:post, path, json: body) do
      {:ok, response} ->
        {:ok, normalize_pipes_access_token_response(response)}

      {:error, error} ->
        log_error("get pipes access token", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Lists organization memberships for a WorkOS user.
  """
  @spec list_user_organization_memberships(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_user_organization_memberships(workos_user_id) when is_binary(workos_user_id) do
    case list_organization_memberships(workos_user_id, nil) do
      {:ok, memberships} ->
        {:ok, Enum.filter(memberships, &membership_active?/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns true when the WorkOS user has an active membership in the organization.
  """
  @spec user_has_organization_membership?(String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def user_has_organization_membership?(workos_user_id, organization_id)
      when is_binary(workos_user_id) and is_binary(organization_id) do
    case list_organization_memberships(workos_user_id, organization_id) do
      {:ok, memberships} ->
        {:ok, Enum.any?(memberships, &membership_active?/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a Vault object.
  """
  @spec create_vault_object(map()) :: {:ok, map()} | {:error, term()}
  def create_vault_object(params) when is_map(params) do
    body =
      compact_map(%{
        name: read_value(params, [:name, "name"]),
        value: read_value(params, [:value, "value"]),
        context: normalize_vault_context(read_value(params, [:context, "context"]))
      })

    case api_request(:post, "/vault/objects", json: body) do
      {:ok, response} ->
        {:ok, response}

      {:error, error} ->
        log_error("create vault object", error)
        {:error, normalize_error(error)}
    end
  end

  @doc """
  Deletes a Vault object.
  """
  @spec delete_vault_object(String.t()) :: :ok | {:error, term()}
  def delete_vault_object(object_id) when is_binary(object_id) do
    path = "/vault/objects/#{URI.encode_www_form(object_id)}"

    case api_request(:delete, path, []) do
      {:ok, _response} ->
        :ok

      {:error, error} ->
        log_error("delete vault object", error)
        {:error, normalize_error(error)}
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

  defp ensure_organization(%Organization{workos_organization_id: workos_organization_id})
       when is_binary(workos_organization_id),
       do: {:ok, workos_organization_id}

  defp ensure_organization(%Organization{} = organization) do
    with {:ok, organization} <- create_organization(organization) do
      {:ok, organization.id}
    end
  end

  defp find_or_create_organization_membership(workos_user_id, workos_organization_id, role) do
    desired_role_slug = role_slug_for(role)

    with {:ok, memberships} <-
           list_organization_memberships(workos_user_id, workos_organization_id) do
      case select_active_membership(memberships) do
        nil ->
          with {:ok, created_membership} <-
                 create_organization_membership(
                   workos_user_id,
                   workos_organization_id,
                   desired_role_slug
                 ),
               {:ok, id} <- membership_id(created_membership) do
            {:ok, id}
          end

        membership ->
          with {:ok, id} <- membership_id(membership),
               :ok <- maybe_sync_membership_role(id, membership, desired_role_slug) do
            {:ok, id}
          end
      end
    end
  end

  defp maybe_sync_membership_role(_membership_id, _membership, nil), do: :ok

  defp maybe_sync_membership_role(membership_id, membership, desired_role_slug) do
    if membership_has_role_slug?(membership, desired_role_slug) do
      :ok
    else
      case update_organization_membership_role(membership_id, desired_role_slug) do
        {:ok, _updated_membership} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp update_organization_membership_role(membership_id, role_slug)
       when is_binary(membership_id) and is_binary(role_slug) do
    case api_request(
           :put,
           "/user_management/organization_memberships/#{membership_id}",
           json: %{role_slug: role_slug}
         ) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, error} ->
        log_error("update organization membership", error)
        {:error, normalize_error(error)}
    end
  end

  defp list_organization_memberships(workos_user_id, workos_organization_id) do
    case api_request(:get, "/user_management/organization_memberships",
           query: %{
             user_id: workos_user_id,
             organization_id: workos_organization_id,
             limit: 10
           }
         ) do
      {:ok, response} ->
        {:ok, extract_membership_data(response)}

      {:error, error} ->
        log_error("list organization memberships", error)
        {:error, normalize_error(error)}
    end
  end

  defp select_active_membership(memberships) when is_list(memberships) do
    Enum.find(memberships, &membership_active?/1) ||
      List.first(memberships)
  end

  defp select_active_membership(_memberships), do: nil

  defp membership_active?(membership) do
    case membership_status(membership) do
      "active" -> true
      "" -> true
      _ -> false
    end
  end

  defp membership_status(membership) do
    membership
    |> read_value([:status, "status"])
    |> to_string()
  end

  defp membership_has_role_slug?(membership, desired_role_slug)
       when is_binary(desired_role_slug) do
    membership
    |> membership_role_slugs()
    |> Enum.member?(desired_role_slug)
  end

  defp membership_role_slugs(membership) do
    role_slugs =
      membership
      |> read_value([:roles, "roles"])
      |> List.wrap()
      |> Enum.map(fn role -> read_value(role, [:slug, "slug"]) end)
      |> Enum.filter(&is_binary/1)

    primary_role_slug =
      case read_value(membership, [:role, "role", :role_slug, "role_slug"]) do
        %{} = role -> read_value(role, [:slug, "slug"])
        slug when is_binary(slug) -> slug
        _ -> nil
      end

    [primary_role_slug | role_slugs]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp extract_membership_data(%{data: data}) when is_list(data), do: data
  defp extract_membership_data(%{"data" => data}) when is_list(data), do: data
  defp extract_membership_data(_), do: []

  defp membership_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp membership_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp membership_id(_membership), do: {:error, :invalid_workos_membership}

  defp api_request(method, path, opts) do
    req_opts =
      [
        base_url: WorkOS.base_url(),
        method: method,
        url: path,
        headers: [
          {"authorization", "Bearer #{WorkOS.api_key()}"},
          {"accept", "application/json"}
        ],
        params: normalize_query(opts[:query])
      ]
      |> maybe_put_json(opts[:json])

    case http_client_module().request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, normalize_http_error(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [RuntimeError, WorkOS.ApiKeyMissingError, WorkOS.ClientIdMissingError] ->
      Logger.error("WorkOS API request configuration error: #{Exception.message(error)}")
      {:error, :workos_not_configured}
  end

  defp maybe_put_json(opts, nil), do: opts

  defp maybe_put_json(opts, json) when is_map(json) do
    compacted_json = compact_map(json)

    if map_size(compacted_json) == 0 do
      opts
    else
      Keyword.put(opts, :json, compacted_json)
    end
  end

  defp maybe_put_json(opts, _json), do: opts

  defp normalize_query(nil), do: []

  defp normalize_query(query) when is_map(query) do
    query
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_query(query) when is_list(query) do
    Enum.reject(query, fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_query(_query), do: []

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_widget_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_widget_scopes(_scopes), do: nil

  defp normalize_vault_context(context) when is_map(context), do: context
  defp normalize_vault_context(_context), do: nil

  defp normalize_pipes_access_token_response(response) do
    access_token_payload = read_value(response, [:access_token, "access_token"])
    provider_error = read_value(response, [:error, "error"]) |> normalize_pipes_error_code()

    token =
      case access_token_payload do
        %{} = payload -> read_value(payload, [:access_token, "access_token"])
        _ -> nil
      end

    expires_at =
      case access_token_payload do
        %{} = payload -> read_value(payload, [:expires_at, "expires_at"])
        _ -> nil
      end

    scopes =
      case access_token_payload do
        %{} = payload -> normalize_string_list(read_value(payload, [:scopes, "scopes"]))
        _ -> []
      end

    missing_scopes =
      case access_token_payload do
        %{} = payload ->
          normalize_string_list(read_value(payload, [:missing_scopes, "missing_scopes"]))

        _ ->
          []
      end

    active = read_value(response, [:active, "active"]) in [true, "true"]

    %{
      active: active,
      access_token: token,
      expires_at: expires_at,
      scopes: scopes,
      missing_scopes: missing_scopes,
      error: provider_error
    }
  end

  defp normalize_string_list(value) when is_list(value) do
    Enum.filter(value, &is_binary/1)
  end

  defp normalize_string_list(_value), do: []

  defp normalize_pipes_error_code(nil), do: nil
  defp normalize_pipes_error_code("not_installed"), do: :not_installed
  defp normalize_pipes_error_code("needs_reauthorization"), do: :needs_reauthorization
  defp normalize_pipes_error_code(value) when is_binary(value), do: value
  defp normalize_pipes_error_code(value), do: value

  defp role_slug_for(nil), do: nil

  defp role_slug_for(role) when is_atom(role) do
    Map.get(role_slug_map(), role) || to_string(role)
  end

  defp role_slug_for(role) when is_binary(role) do
    if String.trim(role) == "" do
      nil
    else
      role
    end
  end

  defp role_slug_for(_role), do: nil

  defp role_slug_map do
    Application.get_env(:fizz, :workos_role_slug_map, %{
      owner: "owner",
      admin: "admin",
      member: "member"
    })
  end

  defp normalize_targets(targets) when is_list(targets) do
    Enum.map(targets, fn target ->
      %{
        type: to_string(Map.get(target, :type) || Map.get(target, "type")),
        id: to_string(Map.get(target, :id) || Map.get(target, "id"))
      }
    end)
  end

  defp normalize_targets(_targets), do: []

  defp normalize_error(%WorkOS.Error{code: code, message: message}) when is_binary(code) do
    {:workos_error, code, message}
  end

  defp normalize_error(%WorkOS.Error{message: message}) when is_binary(message),
    do: {:workos_error, message}

  defp normalize_error(error), do: error

  defp normalize_http_error(status, %{"code" => code, "message" => message})
       when is_binary(code) and is_binary(message) do
    {:workos_error, code, message, status}
  end

  defp normalize_http_error(status, %{"message" => message}) when is_binary(message) do
    {:workos_http_error, status, message}
  end

  defp normalize_http_error(status, body), do: {:workos_http_error, status, body}

  defp log_error(operation, error) do
    Logger.error("WorkOS #{operation} failed: #{inspect(error)}")
  end

  defp user_management_module do
    Application.get_env(:fizz, :workos_user_management_module, WorkOS.UserManagement)
  end

  defp organizations_module do
    Application.get_env(:fizz, :workos_organizations_module, WorkOS.Organizations)
  end

  defp audit_logs_module do
    Application.get_env(:fizz, :workos_audit_logs_module, WorkOS.AuditLogs)
  end

  defp http_client_module do
    Application.get_env(:fizz, :workos_http_client_module, Req)
  end

  defp read_value(data, keys) do
    Enum.find_value(keys, fn key ->
      case data do
        %{} -> Map.get(data, key)
        _ -> nil
      end
    end)
  end
end
