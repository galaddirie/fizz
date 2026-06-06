defmodule Fizz.Workflows.Runtime.ContextBuilder do
  @moduledoc """
  Rebuilds per-run runtime context for workflow execution.

  The compiler produces a reusable `Runic.Workflow` graph. This module provides
  the run-specific context that should not be baked into that compiled artifact,
  such as the run identity, project and organization metadata, current scope,
  and the credential resolver used for per-user credential bindings.

  The result is attached to the workflow at worker start and can be rebuilt on
  resume from durable metadata.
  """

  alias Fizz.Accounts.Scope
  alias Fizz.Fields.Credential
  alias Fizz.Workflows.ExecutionContext
  alias Fizz.Workflows.WorkflowRun

  @doc """
  Builds the runtime context map injected into a compiled Runic workflow.
  """
  def build_run_context(scope, %WorkflowRun{} = run) do
    run
    |> base_context()
    |> maybe_put_scope(scope)
    |> maybe_put_credential_resolver(scope, run)
    |> put_global_context()
  end

  def build_run_context(scope, attrs) when is_map(attrs) do
    attrs
    |> base_context()
    |> maybe_put_scope(scope)
    |> maybe_put_credential_resolver(scope, attrs)
    |> put_global_context()
  end

  defp base_context(run_like) do
    user_id = fetch_value(run_like, :user_id)
    project_id = fetch_value(run_like, :project_id)
    organization_id = fetch_value(run_like, :workos_organization_id)

    %{
      run_id: fetch_value(run_like, :id),
      user_id: user_id,
      project_id: project_id,
      workos_organization_id: organization_id,
      workflow: %{
        id: fetch_value(run_like, :id),
        definition_id: fetch_value(run_like, :workflow_definition_id),
        definition_version_id: fetch_value(run_like, :workflow_definition_version_id),
        user_id: user_id,
        project_id: project_id,
        workos_organization_id: organization_id,
        compiled_hash: fetch_value(run_like, :compiled_hash)
      },
      env: %{},
      metadata: %{
        user_id: user_id,
        project_id: project_id,
        workos_organization_id: organization_id
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
    |> put_execution_context()
  end

  defp maybe_put_scope(context, _scope), do: context

  defp maybe_put_credential_resolver(context, %Scope{} = scope, run_or_attrs) do
    case Credential.runtime_resolver(scope, run_or_attrs) do
      {:ok, resolver} -> Map.put(context, :_credential_resolver, resolver)
      {:error, _reason} -> context
    end
  end

  defp maybe_put_credential_resolver(context, _scope, _run_or_attrs), do: context

  defp put_global_context(context) do
    context
    |> put_execution_context()
    |> then(&Map.put(&1, :_global, Map.drop(&1, [:_global])))
  end

  defp put_execution_context(context) do
    Map.put(context, :execution_context, ExecutionContext.from_map(context))
  end

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
