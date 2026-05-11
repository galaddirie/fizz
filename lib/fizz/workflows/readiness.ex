defmodule Fizz.Workflows.Readiness do
  @moduledoc """
  Pre-run readiness check for a user against a workflow definition.

  Walks step configs for slot declarations, first auto-binding any safe
  single-choice OAuth credential slots, then reports any slots the user has not
  yet bound. Used by:

    * The editor's run-launch flow — to gate `start_run` with a binding modal.
    * Trigger registration — so a user can't register a webhook/cron trigger
      until their bindings cover the workflow.

  Returns one of:

    * `:ready` — every slot has a binding.
    * `{:needs_bindings, [descriptor]}` — one entry per unbound slot, with
      `candidates` populated by the slot kind's resolver for the run-launch UI.
  """

  alias Fizz.Slots
  alias Fizz.Accounts.Scope
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
    _ = Slots.ensure_auto_bindings(version, user_id, scope)

    Slots.readiness(version, user_id, scope)
  end
end
