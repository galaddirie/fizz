defmodule Fizz.Workflows.Readiness do
  @moduledoc """
  Pre-run readiness check for a user against a workflow definition.

  Walks step configs for credential declarations, first auto-binding any safe
  single-choice OAuth credentials, then reports any credentials the user has not
  yet bound. Used by:

    * The editor's run-launch flow — to gate `start_run` with a binding modal.
    * Trigger registration — so a user can't register a webhook/cron trigger
      until their bindings cover the workflow.

  Returns one of:

    * `:ready` — every credential requirement has a binding.
    * `{:needs_bindings, [descriptor]}` — one entry per unbound credential, with
      `candidates` populated for the run-launch UI.
  """

  alias Fizz.Credentials
  alias Fizz.Accounts.Scope
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @type descriptor :: %{
          step_id: String.t(),
          requirement_key: String.t(),
          provider: String.t(),
          auth_type: String.t(),
          candidates: [map()]
        }

  @spec check(WorkflowDefinitionVersion.t(), String.t(), Scope.t()) ::
          :ready | {:needs_bindings, [descriptor()]}
  def check(%WorkflowDefinitionVersion{} = version, user_id, %Scope{} = scope)
      when is_binary(user_id) do
    _ = Credentials.ensure_auto_bindings(version, user_id, scope)

    Credentials.readiness(version, user_id, scope)
  end
end
