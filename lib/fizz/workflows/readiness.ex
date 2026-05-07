defmodule Fizz.Workflows.Readiness do
  @moduledoc """
  Pre-run readiness check for a user against a workflow definition.

  Walks step configs for slot declarations and reports any slots the user has
  not yet bound. Used by:

    * The editor's run-launch flow — to gate `start_run` with a binding modal.
    * Trigger registration — so a user can't register a webhook/cron trigger
      until their bindings cover the workflow.

  Returns one of:

    * `:ready` — every slot has a binding.
    * `{:needs_bindings, [descriptor]}` — one entry per unbound slot, with
      `candidates` populated by the slot kind's resolver for the run-launch UI.
  """

  alias Fizz.Accounts.Scope
  alias Fizz.Slots
  alias Fizz.Slots.Registry, as: SlotRegistry
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @type descriptor :: %{
          step_id: String.t(),
          slot_key: String.t(),
          kind: String.t(),
          spec: map(),
          candidates: [map()]
        }

  @spec check(WorkflowDefinitionVersion.t(), String.t(), Scope.t()) ::
          :ready | {:needs_bindings, [descriptor()]}
  def check(%WorkflowDefinitionVersion{} = version, user_id, %Scope{} = scope)
      when is_binary(user_id) do
    workflow_definition_id = version.workflow_definition_id
    organization_id = scope.organization_id

    bindings =
      if is_binary(workflow_definition_id) and is_binary(organization_id) do
        organization_id
        |> Slots.list_for_user(workflow_definition_id, user_id)
        |> Map.new(fn binding -> {{binding.step_id, binding.slot_key}, binding} end)
      else
        %{}
      end

    descriptors =
      version.steps
      |> List.wrap()
      |> Enum.flat_map(&slot_decls_for_step/1)
      |> Enum.reject(fn %{step_id: step_id, slot_key: slot_key} ->
        Map.has_key?(bindings, {step_id, slot_key})
      end)
      |> Enum.map(&attach_candidates(&1, scope))

    case descriptors do
      [] -> :ready
      _ -> {:needs_bindings, descriptors}
    end
  end

  defp slot_decls_for_step(step) when is_map(step) do
    step_id = Map.get(step, "id") || Map.get(step, :id)
    config = Map.get(step, "config") || Map.get(step, :config) || %{}

    if is_binary(step_id) do
      walk(config)
      |> Enum.map(fn decl ->
        %{
          step_id: step_id,
          slot_key: Map.get(decl, "slot_key"),
          kind: Map.get(decl, "kind"),
          spec: Map.get(decl, "spec") || %{}
        }
      end)
    else
      []
    end
  end

  defp slot_decls_for_step(_step), do: []

  defp walk(%{"$slot" => true} = decl), do: [decl]

  defp walk(map) when is_map(map) do
    Enum.flat_map(map, fn {_key, value} -> walk(value) end)
  end

  defp walk(list) when is_list(list), do: Enum.flat_map(list, &walk/1)

  defp walk(_value), do: []

  defp attach_candidates(%{kind: kind, spec: spec} = descriptor, scope) do
    candidates =
      case SlotRegistry.fetch(kind) do
        {:ok, module} ->
          case module.candidate_options(spec, scope) do
            {:ok, options} -> options
            _ -> []
          end

        :error ->
          []
      end

    Map.put(descriptor, :candidates, candidates)
  end
end
