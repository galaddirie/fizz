defmodule Fizz.Workflows.Runtime.ContextBuilder do
  @moduledoc """
  Rebuilds per-run runtime context for workflow execution.

  The compiler produces a reusable `Runic.Workflow` graph. This module provides
  the run-specific context that should not be baked into that compiled artifact,
  such as the run identity, project and organization metadata, current scope,
  and integration credential resolver.

  The result is attached to the workflow at worker start and can be rebuilt on
  resume from durable metadata.
  """

  alias Fizz.Accounts.Scope
  alias Fizz.Integrations.ProviderCatalog
  alias Fizz.Workflows.WorkflowRun

  @doc """
  Builds the runtime context map injected into a compiled Runic workflow.
  """
  def build_run_context(scope, %WorkflowRun{} = run) do
    run
    |> base_context()
    |> maybe_put_scope(scope)
    |> maybe_put_credential_resolver(scope, run.workos_organization_id)
  end

  def build_run_context(scope, attrs) when is_map(attrs) do
    attrs
    |> base_context()
    |> maybe_put_scope(scope)
    |> maybe_put_credential_resolver(scope, fetch_value(attrs, :workos_organization_id))
  end

  defp base_context(run_like) do
    %{
      workflow: %{
        id: fetch_value(run_like, :id),
        definition_id: fetch_value(run_like, :workflow_definition_id),
        definition_version_id: fetch_value(run_like, :workflow_definition_version_id),
        project_id: fetch_value(run_like, :project_id),
        workos_organization_id: fetch_value(run_like, :workos_organization_id),
        compiled_hash: fetch_value(run_like, :compiled_hash)
      },
      env: %{},
      metadata: %{
        project_id: fetch_value(run_like, :project_id),
        workos_organization_id: fetch_value(run_like, :workos_organization_id)
      }
    }
  end

  defp maybe_put_scope(context, %Scope{} = scope) do
    metadata =
      context.metadata
      |> Map.put(:scope, scope)
      |> Map.put(:current_scope, scope)

    context
    |> Map.put(:scope, scope)
    |> Map.put(:current_scope, scope)
    |> Map.put(:metadata, metadata)
  end

  defp maybe_put_scope(context, _scope), do: context

  defp maybe_put_credential_resolver(context, %Scope{} = scope, organization_id)
       when is_binary(organization_id) and byte_size(organization_id) > 0 do
    Map.put(
      context,
      :_credential_resolver,
      fn credential_ref ->
        with {:ok, provider_id} <- provider_id_from_ref(credential_ref),
             {:ok, auth_type} <- auth_type_from_ref(credential_ref),
             {:ok, provider_module} <- provider_module(provider_id, auth_type),
             {:ok, token_result} <- provider_module.fetch_token(scope, organization_id) do
          token_result
        else
          _ -> nil
        end
      end
    )
  end

  defp maybe_put_credential_resolver(context, _scope, _organization_id), do: context

  defp provider_module(provider_id, auth_type) do
    with {:ok, provider} <- ProviderCatalog.provider_for_type(provider_id, auth_type) do
      case auth_type do
        :oauth when is_atom(provider.oauth_module) -> {:ok, provider.oauth_module}
        :api_key when is_atom(provider.api_key_module) -> {:ok, provider.api_key_module}
        _ -> {:error, :provider_not_implemented}
      end
    end
  end

  defp provider_id_from_ref(ref) when is_map(ref) do
    case fetch_value(ref, :provider) do
      provider_id when is_binary(provider_id) and byte_size(provider_id) > 0 ->
        {:ok, provider_id}

      _ ->
        {:error, :provider_not_set}
    end
  end

  defp provider_id_from_ref(_ref), do: {:error, :provider_not_set}

  defp auth_type_from_ref(ref) when is_map(ref) do
    case fetch_value(ref, :auth_type) do
      "oauth" -> {:ok, :oauth}
      "api_key" -> {:ok, :api_key}
      :oauth -> {:ok, :oauth}
      :api_key -> {:ok, :api_key}
      nil -> {:ok, :api_key}
      _ -> {:error, :invalid_auth_type}
    end
  end

  defp auth_type_from_ref(_ref), do: {:ok, :api_key}

  defp fetch_value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_value(_map, _key), do: nil
end
