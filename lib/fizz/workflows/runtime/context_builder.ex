defmodule Fizz.Workflows.Runtime.ContextBuilder do
  @moduledoc """
  Rebuilds per-run runtime context for workflow execution.

  The compiler produces a reusable `Runic.Workflow` graph. This module provides
  the run-specific context that should not be baked into that compiled artifact,
  such as the run identity, project and organization metadata, current scope,
  and the slot resolver used for per-user value bindings (credentials, etc.).

  The result is attached to the workflow at worker start and can be rebuilt on
  resume from durable metadata.
  """

  alias Fizz.Accounts.Scope
  alias Fizz.Slots
  alias Fizz.Slots.Registry
  alias Fizz.Workflows.WorkflowRun

  @doc """
  Builds the runtime context map injected into a compiled Runic workflow.
  """
  def build_run_context(scope, %WorkflowRun{} = run) do
    run
    |> base_context()
    |> maybe_put_scope(scope)
    |> maybe_put_slot_resolver(scope, run)
  end

  def build_run_context(scope, attrs) when is_map(attrs) do
    attrs
    |> base_context()
    |> maybe_put_scope(scope)
    |> maybe_put_slot_resolver(scope, attrs)
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

  defp maybe_put_slot_resolver(context, %Scope{} = scope, run_or_attrs) do
    with {:ok, user_id} <- user_id_for_run(run_or_attrs, scope),
         {:ok, workflow_definition_id} <- workflow_definition_id(run_or_attrs),
         {:ok, organization_id} <- organization_id(run_or_attrs) do
      bindings =
        organization_id
        |> Slots.list_for_user(workflow_definition_id, user_id)
        |> Map.new(fn binding -> {{binding.step_id, binding.slot_key}, binding} end)

      resolver = fn kind, slot_key, step_id, spec ->
        with {:ok, module} <- Registry.fetch(kind),
             binding when not is_nil(binding) <-
               Map.get(bindings, {step_id, slot_key}) do
          module.resolve(spec, binding.binding_data, scope)
        else
          _ -> {:error, :slot_unbound}
        end
      end

      Map.put(context, :_slot_resolver, resolver)
    else
      _ -> context
    end
  end

  defp maybe_put_slot_resolver(context, _scope, _run_or_attrs), do: context

  defp user_id_for_run(run_or_attrs, scope) when is_map(run_or_attrs) do
    case fetch_value(run_or_attrs, :user_id) do
      user_id when is_binary(user_id) and user_id != "" ->
        {:ok, user_id}

      _ ->
        case scope do
          %Scope{user: %{id: user_id}} when is_binary(user_id) -> {:ok, user_id}
          _ -> {:error, :user_id_required}
        end
    end
  end

  defp workflow_definition_id(run_or_attrs) do
    case fetch_value(run_or_attrs, :workflow_definition_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :workflow_definition_id_required}
    end
  end

  defp organization_id(run_or_attrs) do
    case fetch_value(run_or_attrs, :workos_organization_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :organization_id_required}
    end
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
