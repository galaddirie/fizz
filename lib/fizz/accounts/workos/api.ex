defmodule Fizz.Accounts.WorkOS.Api do
  @moduledoc """
  Direct WorkOS API operations: audit events, widget tokens, Pipes access
  tokens, and Vault objects.
  """

  require Logger

  import Fizz.Accounts.WorkOS.Helpers
  import Fizz.Accounts.WorkOS.Http

  alias Fizz.Accounts.User

  @doc """
  Emits an audit event to WorkOS for a WorkOS organization.
  """
  @spec create_audit_event(String.t(), %User{}, String.t(), [map()], map()) ::
          :ok | {:error, term()}
  def create_audit_event(
        workos_organization_id,
        %User{} = actor,
        action,
        targets,
        context
      )
      when is_binary(workos_organization_id) and is_binary(action) do
    if Fizz.Accounts.WorkOS.Memberships.enabled?() do
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

  defp normalize_targets(targets) when is_list(targets) do
    Enum.map(targets, fn target ->
      %{
        type: to_string(Map.get(target, :type) || Map.get(target, "type")),
        id: to_string(Map.get(target, :id) || Map.get(target, "id"))
      }
    end)
  end

  defp normalize_targets(_targets), do: []

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

    {token, expires_at, scopes, missing_scopes} =
      case access_token_payload do
        %{} = payload ->
          {
            read_value(payload, [:access_token, "access_token"]),
            read_value(payload, [:expires_at, "expires_at"]),
            normalize_string_list(read_value(payload, [:scopes, "scopes"])),
            normalize_string_list(read_value(payload, [:missing_scopes, "missing_scopes"]))
          }

        _ ->
          {nil, nil, [], []}
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

  defp audit_logs_module do
    Application.get_env(:fizz, :workos_audit_logs_module, WorkOS.AuditLogs)
  end
end
