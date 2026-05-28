defmodule Fizz.Workflows do
  @moduledoc """
  Project-scoped context for workflow authoring, compilation, and run lifecycle
  management.

  `Fizz.Workflows` is the public facade for workflow authoring and runtime
  operations. Implementation details live in focused internal modules under
  `Fizz.Workflows.Authoring` and `Fizz.Workflows.Runtime`.
  """

  alias Fizz.Accounts.Scope
  alias Fizz.Workflows.Authoring
  alias Fizz.Workflows.DraftSession
  alias Fizz.Workflows.DraftSession.Operation
  alias Fizz.Workflows.Runtime.{Runs, Signals, StepExecutions, Timers}

  alias Fizz.Workflows.{SignalInbox, WorkflowDefinition, WorkflowDefinitionVersion, WorkflowRun}

  @type error_reason ::
          :definition_not_found
          | :not_a_draft
          | :project_scope_required
          | :published_version_not_found
          | :run_not_found
          | :unauthenticated
          | :version_not_found
          | [map()]
          | term()
          | Ecto.Changeset.t()

  @spec create_definition(Scope.t() | nil, map()) ::
          {:ok, %{definition: %WorkflowDefinition{}, draft: %WorkflowDefinitionVersion{}}}
          | {:error, error_reason()}
  defdelegate create_definition(scope, attrs), to: Authoring

  @spec save_draft(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t(), map()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  defdelegate save_draft(scope, version, attrs), to: Authoring

  @spec publish_draft(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  defdelegate publish_draft(scope, version), to: Authoring

  @spec edit_definition(Scope.t() | nil, %WorkflowDefinition{} | String.t()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  defdelegate edit_definition(scope, definition), to: Authoring

  @spec get_version(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  defdelegate get_version(scope, version), to: Authoring

  @spec archive_definition(Scope.t() | nil, %WorkflowDefinition{} | String.t()) ::
          {:ok, %WorkflowDefinition{}} | {:error, error_reason()}
  defdelegate archive_definition(scope, definition), to: Authoring

  @spec get_definition(Scope.t() | nil, String.t()) ::
          {:ok, %WorkflowDefinition{}} | {:error, error_reason()}
  defdelegate get_definition(scope, id), to: Authoring

  @spec list_definitions(Scope.t() | nil) ::
          {:ok, [%WorkflowDefinition{}]} | {:error, error_reason()}
  defdelegate list_definitions(scope), to: Authoring

  @spec start_run(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t(), term(), keyword()) ::
          {:ok, %WorkflowRun{}} | {:error, error_reason()}
  @doc """
  Starts a new workflow run for a published definition version.
  """
  def start_run(scope, version, input, opts \\ [])

  def start_run(scope, %WorkflowDefinitionVersion{id: version_id} = version, input, opts)
      when is_binary(version_id) do
    with {:ok, _authorized_version} <- Authoring.get_version(scope, version_id) do
      Runs.start_run(scope, version, input, opts)
    end
  end

  def start_run(scope, version, input, opts) do
    with {:ok, version_record} <- Authoring.get_version(scope, version) do
      Runs.start_run(scope, version_record, input, opts)
    end
  end

  @spec get_run(Scope.t() | nil, String.t()) :: {:ok, %WorkflowRun{}} | {:error, error_reason()}
  @doc """
  Fetches a single workflow run scoped to the current project.
  """
  defdelegate get_run(scope, run_id), to: Runs

  @spec list_run_step_executions(Scope.t() | nil, String.t()) ::
          {:ok, [map()]} | {:error, error_reason()}
  def list_run_step_executions(scope, run_id) when is_binary(run_id) do
    with {:ok, run} <- Runs.get_run(scope, run_id),
         {:ok, version} <- Authoring.get_version(scope, run.workflow_definition_version_id) do
      StepExecutions.list(run, version)
    end
  end

  @spec load_run_step_io(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, map()} | {:error, error_reason()}
  def load_run_step_io(scope, run_id, step_execution_id)
      when is_binary(run_id) and is_binary(step_execution_id) do
    with {:ok, run} <- Runs.get_run(scope, run_id),
         {:ok, version} <- Authoring.get_version(scope, run.workflow_definition_version_id) do
      StepExecutions.load_io(run, version, step_execution_id)
    end
  end

  @spec list_runs(Scope.t() | nil, keyword()) ::
          {:ok, [%WorkflowRun{}]} | {:error, error_reason()}
  @doc """
  Lists workflow runs for the current project.

  Supported filters:

  - `:status` - one status or a list of statuses
  - `:definition_id` - workflow definition id
  """
  defdelegate list_runs(scope, opts \\ []), to: Runs

  @spec cancel_run(Scope.t() | nil, String.t()) ::
          {:ok, %WorkflowRun{}} | {:error, error_reason()}
  @doc """
  Cancels a workflow run, cancels any pending timers, and stops its worker if
  one is active.
  """
  defdelegate cancel_run(scope, run_id), to: Runs

  @spec signal_run(Scope.t() | nil, String.t(), String.t(), term(), String.t()) ::
          {:ok, %SignalInbox{}} | {:error, error_reason()}
  @doc """
  Accepts an external signal into the durable inbox.
  """
  defdelegate signal_run(scope, run_id, signal_name, payload, signal_id), to: Runs

  @doc false
  defdelegate create_timer(run_id, step_id, fire_at, opts \\ []), to: Timers

  @doc false
  defdelegate claim_due_timers(opts \\ []), to: Timers

  @doc false
  defdelegate claim_timer(timer_id, opts \\ []), to: Timers

  @doc false
  defdelegate recover_stale_timers(opts \\ []), to: Timers

  @doc false
  defdelegate release_timer_claim(timer_id), to: Timers

  @doc false
  defdelegate get_timer(timer_id), to: Timers

  @doc false
  defdelegate mark_timer_fired(timer_id), to: Timers

  @doc false
  defdelegate run_has_pending_timers?(run_id), to: Timers

  @doc false
  defdelegate sleep_run(run_id), to: Runs

  @doc false
  defdelegate resume_run(run_id), to: Runs

  @doc false
  defdelegate record_run_retry(run_id, error_payload, opts \\ []), to: Runs

  @doc false
  defdelegate clear_run_error(run_id), to: Runs

  @doc false
  defdelegate create_signal_inbox(run_id, signal_id, signal_name, payload), to: Signals

  @doc false
  defdelegate claim_pending_signals(opts \\ []), to: Signals

  @doc false
  defdelegate claim_signal(signal_id, opts \\ []), to: Signals

  @doc false
  defdelegate recover_stale_signals(opts \\ []), to: Signals

  @doc false
  defdelegate release_signal_claim(signal_id), to: Signals

  @doc false
  defdelegate get_signal(signal_id), to: Signals

  @doc false
  defdelegate mark_signal_delivered(signal_id), to: Signals

  @doc false
  defdelegate mark_signal_skipped(signal_id), to: Signals

  @doc false
  defdelegate deliver_run_event(run_id, event, opts \\ []), to: Runs

  @doc false
  defdelegate touch_run_activity(run_id), to: Runs

  @doc false
  defdelegate complete_run(run_id, output), to: Runs

  @doc false
  defdelegate fail_run(run_id, reason), to: Runs

  @doc false
  defdelegate passivate_run(run_id), to: Runs

  @doc false
  defdelegate list_passivation_candidates(idle_before, limit \\ 50), to: Runs

  @doc false
  defdelegate release_run_lease(run_id), to: Runs

  @doc """
  Joins the collaborative draft session for a workflow definition version.
  """
  defdelegate join_draft_session(version_id, scope, user_id), to: DraftSession, as: :join

  @doc """
  Leaves the collaborative draft session for a workflow definition version.
  """
  defdelegate leave_draft_session(version_id, user_id), to: DraftSession, as: :leave

  @doc """
  Applies a structural operation to the authoritative draft session.
  """
  defdelegate apply_draft_operation(version_id, user_id, operation),
    to: DraftSession,
    as: :apply_operation

  @doc false
  defdelegate apply_draft_operation_to_snapshot(draft, operation),
    to: Operation,
    as: :apply

  @doc """
  Applies the current user's next undo operation in the draft session.
  """
  defdelegate undo_draft_operation(version_id, user_id), to: DraftSession, as: :undo

  @doc """
  Applies the current user's next redo operation in the draft session.
  """
  defdelegate redo_draft_operation(version_id, user_id), to: DraftSession, as: :redo

  @doc """
  Persists the current in-memory draft immediately.
  """
  defdelegate persist_draft_now(version_id), to: DraftSession, as: :persist_now

  @doc """
  Reads the current user's undo and redo state for a draft session.
  """
  defdelegate get_draft_undo_state(version_id, user_id), to: DraftSession, as: :get_undo_state

  @doc """
  Reads the persistence state for a draft session.
  """
  defdelegate get_draft_persistence_state(version_id),
    to: DraftSession,
    as: :get_persistence_state

  @doc """
  Reads the editor-only state for a draft session.
  """
  defdelegate get_draft_editor_state(version_id), to: DraftSession, as: :get_editor_state

  @doc """
  Previews a draft revision from the current draft session.
  """
  defdelegate preview_draft_revision(version_id, user_id, revision),
    to: DraftSession,
    as: :preview_revision

  @doc """
  Pins a step output in editor-only draft session state.
  """
  defdelegate pin_draft_step_output(version_id, step_id, output_data),
    to: DraftSession,
    as: :pin_output

  @doc """
  Removes a pinned step output from editor-only draft session state.
  """
  defdelegate unpin_draft_step_output(version_id, step_id), to: DraftSession, as: :unpin_output

  @doc """
  Disables a step in editor-only draft session state.
  """
  defdelegate disable_draft_step(version_id, step_id), to: DraftSession, as: :disable_step

  @doc """
  Enables a step in editor-only draft session state.
  """
  defdelegate enable_draft_step(version_id, step_id), to: DraftSession, as: :enable_step

  @doc """
  Reads the current draft session snapshot.
  """
  defdelegate get_draft_snapshot(version_id, user_id), to: DraftSession, as: :snapshot
end
