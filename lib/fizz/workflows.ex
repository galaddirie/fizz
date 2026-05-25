defmodule Fizz.Workflows do
  @moduledoc """
  Project-scoped context for workflow authoring, compilation, and run lifecycle
  management.

  This context owns both sides of the workflow system:

  - definition CRUD and publishing for authored workflow graphs
  - runtime operations for creating, looking up, cancelling, and passivating
    workflow runs

  Phase 4 extends the context with the runtime entrypoints that turn a published
  `WorkflowDefinitionVersion` into a durable `WorkflowRun` backed by a worker,
  lease, and checkpoint store.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Fizz.Accounts.{Project, Scope}
  alias Fizz.Repo
  alias Fizz.Slots
  alias Fizz.Triggers.RegistrationManager
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.Embeds.Step
  alias Fizz.Workflows.PublishValidation
  alias Fizz.Workflows.Readiness
  alias Fizz.Workflows.Runner.{Worker, WorkerSupervisor}
  alias Fizz.Workflows.Runtime.ContextBuilder
  alias Fizz.Workflows.StepExecutionTrace
  alias Fizz.Workflows.Store.{LitestreamManager, SqliteStore}

  alias Fizz.Workflows.{
    DurableTimer,
    SignalInbox,
    SlotDefaults,
    WorkflowDefinition,
    WorkflowDefinitionVersion,
    WorkflowRun
  }

  alias Runic.Workflow
  alias Runic.Workflow.{ComponentAdded, RunnableCompleted, RunnableDispatched, RunnableFailed}

  require Logger

  @default_snapshot_attrs %{
    steps: [],
    connections: [],
    step_groups: [],
    viewport: WorkflowDefinitionVersion.default_viewport(),
    settings: %{}
  }
  @run_statuses WorkflowRun.statuses()

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
  def create_definition(scope, attrs) when is_map(attrs) do
    with {:ok, project} <- project_from_scope(scope),
         {:ok, user_id} <- user_id_from_scope(scope) do
      definition_attrs =
        attrs
        |> Map.put(:project_id, project.id)
        |> Map.put(:workos_organization_id, project.workos_organization_id)
        |> Map.put(:created_by_user_id, user_id)

      Multi.new()
      |> Multi.insert(
        :definition,
        WorkflowDefinition.changeset(%WorkflowDefinition{}, definition_attrs)
      )
      |> Multi.insert(:draft, fn %{definition: definition} ->
        WorkflowDefinitionVersion.save_changeset(
          %WorkflowDefinitionVersion{},
          initial_draft_attrs(definition.id)
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{definition: definition, draft: draft}} ->
          {:ok, %{definition: definition, draft: draft}}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def create_definition(_scope, _attrs), do: {:error, :project_scope_required}

  @spec save_draft(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t(), map()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  def save_draft(scope, version, attrs) when is_map(attrs) do
    with {:ok, version_record} <- fetch_version(scope, version),
         :ok <- ensure_draft(version_record) do
      version_record
      |> WorkflowDefinitionVersion.save_changeset(normalize_snapshot_attrs(attrs))
      |> Repo.update()
    end
  end

  def save_draft(_scope, _version, _attrs), do: {:error, :project_scope_required}

  @spec publish_draft(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  def publish_draft(scope, version) do
    with {:ok, version_record} <- fetch_version(scope, version),
         :ok <- ensure_draft(version_record),
         {:ok, user_id} <- user_id_from_scope(scope) do
      version_record = SlotDefaults.normalize_version(version_record)
      _ = Slots.ensure_auto_bindings(version_record, user_id, scope)

      published_at = DateTime.utc_now()

      changeset =
        WorkflowDefinitionVersion.publish_changeset(version_record, %{
          steps: Enum.map(version_record.steps, &embed_to_attrs/1),
          status: :published,
          compiled_hash: provisional_compiled_hash(),
          published_at: published_at,
          published_by_user_id: user_id
        })

      if changeset.valid? do
        compiled_version = Ecto.Changeset.apply_changes(changeset)

        case Compiler.compile(compiled_version) do
          {:ok, _workflow, compiled_hash} ->
            changeset
            |> Ecto.Changeset.put_change(:compiled_hash, compiled_hash)
            |> Repo.update()
            |> maybe_sync_trigger_registrations()

          {:error, errors} ->
            {:error, add_compile_errors(changeset, errors)}
        end
      else
        {:error, changeset}
      end
    end
  end

  @spec edit_definition(Scope.t() | nil, %WorkflowDefinition{} | String.t()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  def edit_definition(scope, definition) do
    with {:ok, definition_record} <- fetch_definition(scope, definition) do
      case latest_draft_version(definition_record.id) do
        %WorkflowDefinitionVersion{} = draft ->
          {:ok, draft}

        nil ->
          case latest_published_version(definition_record.id) do
            %WorkflowDefinitionVersion{} = published_version ->
              %WorkflowDefinitionVersion{}
              |> WorkflowDefinitionVersion.save_changeset(
                clone_draft_attrs(definition_record.id, published_version)
              )
              |> Repo.insert()

            nil ->
              {:error, :published_version_not_found}
          end
      end
    end
  end

  @spec get_version(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  def get_version(scope, version) do
    fetch_version(scope, version)
  end

  @spec archive_definition(Scope.t() | nil, %WorkflowDefinition{} | String.t()) ::
          {:ok, %WorkflowDefinition{}} | {:error, error_reason()}
  def archive_definition(scope, definition) do
    with {:ok, definition_record} <- fetch_definition(scope, definition) do
      archived_at = definition_record.archived_at || DateTime.utc_now()

      definition_record
      |> WorkflowDefinition.changeset(%{archived_at: archived_at})
      |> Repo.update()
    end
  end

  @spec get_definition(Scope.t() | nil, String.t()) ::
          {:ok, %WorkflowDefinition{}} | {:error, error_reason()}
  def get_definition(scope, id) when is_binary(id) do
    with {:ok, project} <- project_from_scope(scope) do
      versions_query =
        from(version in WorkflowDefinitionVersion,
          order_by: [desc: version.version]
        )

      definition =
        from(definition in WorkflowDefinition,
          where: definition.project_id == ^project.id and definition.id == ^id,
          preload: [versions: ^versions_query]
        )
        |> Repo.one()

      case definition do
        %WorkflowDefinition{} = definition_record -> {:ok, definition_record}
        nil -> {:error, :definition_not_found}
      end
    end
  end

  @spec list_definitions(Scope.t() | nil) ::
          {:ok, [%WorkflowDefinition{}]} | {:error, error_reason()}
  def list_definitions(scope) do
    with {:ok, project} <- project_from_scope(scope) do
      definitions =
        from(definition in WorkflowDefinition,
          where: definition.project_id == ^project.id and is_nil(definition.archived_at),
          order_by: [asc: definition.name]
        )
        |> Repo.all()

      {:ok, definitions}
    end
  end

  @spec start_run(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t(), term(), keyword()) ::
          {:ok, %WorkflowRun{}} | {:error, error_reason()}
  @doc """
  Starts a new workflow run for a published definition version.

  The run is created in `:pending`, a lease row is created and acquired, the
  workflow is compiled, runtime context is attached, the SQLite checkpoint store
  is initialized, and a worker is started. Once the worker is ready the run is
  transitioned to `:running` and the initial input is dispatched.
  """
  def start_run(scope, version, input, opts \\ [])

  def start_run(scope, %WorkflowDefinitionVersion{id: version_id} = version, input, opts)
      when is_binary(version_id) do
    with {:ok, _authorized_version} <- fetch_version(scope, version_id) do
      do_start_run(scope, version, input, opts)
    end
  end

  def start_run(scope, version, input, opts) do
    with {:ok, version_record} <- fetch_version(scope, version) do
      do_start_run(scope, version_record, input, opts)
    end
  end

  @spec get_run(Scope.t() | nil, String.t()) :: {:ok, %WorkflowRun{}} | {:error, error_reason()}
  @doc """
  Fetches a single workflow run scoped to the current project.
  """
  def get_run(scope, run_id) when is_binary(run_id) do
    with {:ok, project} <- project_from_scope(scope) do
      run =
        from(run in WorkflowRun,
          where: run.project_id == ^project.id and run.id == ^run_id
        )
        |> Repo.one()

      case run do
        %WorkflowRun{} = workflow_run -> {:ok, workflow_run}
        nil -> {:error, :run_not_found}
      end
    end
  end

  @spec list_run_step_executions(Scope.t() | nil, String.t()) ::
          {:ok, [map()]} | {:error, error_reason()}
  def list_run_step_executions(scope, run_id) when is_binary(run_id) do
    with {:ok, run} <- get_run(scope, run_id),
         {:ok, version} <- get_version(scope, run.workflow_definition_version_id),
         {:ok, store_state} <- init_run_store(run),
         {:ok, event_log} <- load_run_event_log(run, store_state) do
      {:ok, build_step_executions(run, version, event_log, store_state)}
    else
      {:error, :checkpoint_not_found} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_run_step_io(Scope.t() | nil, String.t(), String.t()) ::
          {:ok, map()} | {:error, error_reason()}
  def load_run_step_io(scope, run_id, step_execution_id)
      when is_binary(run_id) and is_binary(step_execution_id) do
    with {:ok, run} <- get_run(scope, run_id),
         {:ok, version} <- get_version(scope, run.workflow_definition_version_id),
         {:ok, store_state} <- init_run_store(run),
         {:ok, event_log} <- load_run_event_log(run, store_state),
         {:ok, step_execution} <-
           find_step_execution(run, version, event_log, store_state, step_execution_id) do
      metadata = Map.get(step_execution, :metadata, %{})

      {:ok,
       %{
         step_execution_id: step_execution.id,
         execution_id: step_execution.execution_id,
         step_id: step_execution.step_id,
         attempt: step_execution.attempt,
         input_data:
           load_fact_value(
             Map.get(metadata, :input_fact_hash),
             store_state,
             Map.get(step_execution, :input_data)
           ),
         output_data:
           load_fact_value(
             Map.get(metadata, :output_fact_hash),
             store_state,
             Map.get(step_execution, :output_data)
           )
       }}
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
  def list_runs(scope, opts \\ []) do
    with {:ok, project} <- project_from_scope(scope) do
      runs =
        WorkflowRun
        |> where([run], run.project_id == ^project.id)
        |> maybe_filter_run_status(Keyword.get(opts, :status))
        |> maybe_filter_definition_id(Keyword.get(opts, :definition_id))
        |> order_by([run], desc: run.inserted_at)
        |> Repo.all()

      {:ok, runs}
    end
  end

  @spec cancel_run(Scope.t() | nil, String.t()) ::
          {:ok, %WorkflowRun{}} | {:error, error_reason()}
  @doc """
  Cancels a workflow run, cancels any pending timers, and stops its worker if
  one is active.
  """
  def cancel_run(scope, run_id) when is_binary(run_id) do
    with {:ok, run} <- get_run(scope, run_id),
         :ok <- maybe_stop_worker(run.id, persist: true),
         {:ok, cancelled_run} <- transition_run_status(run.id, :cancelled) do
      :ok = cancel_pending_timers(cancelled_run.id)
      :ok = release_run_lease(cancelled_run.id)

      _ =
        broadcast_run_event(
          cancelled_run.id,
          {:run_status_changed,
           %{
             run_id: cancelled_run.id,
             status: :cancelled,
             timestamp: DateTime.utc_now()
           }}
        )

      {:ok, cancelled_run}
    end
  end

  @spec signal_run(Scope.t() | nil, String.t(), String.t(), term(), String.t()) ::
          {:ok, %SignalInbox{}} | {:error, error_reason()}
  @doc """
  Accepts an external signal into the durable inbox and attempts delivery.
  """
  def signal_run(scope, run_id, signal_name, payload, signal_id) do
    with {:ok, run} <- get_run(scope, run_id) do
      Fizz.Workflows.SignalRouter.accept_signal(run.id, signal_id, signal_name, payload)
    end
  end

  @doc false
  def create_timer(run_id, step_id, fire_at, opts \\ [])

  def create_timer(run_id, step_id, %DateTime{} = fire_at, opts)
      when is_binary(run_id) and is_binary(step_id) and is_list(opts) do
    with {:ok, run} <- fetch_run(run_id) do
      attrs = %{
        run_id: run.id,
        step_id: step_id,
        timer_name: Keyword.get(opts, :timer_name, step_id),
        project_id: run.project_id,
        workos_organization_id: run.workos_organization_id,
        fire_at: fire_at,
        status: :pending,
        payload: Keyword.get(opts, :payload)
      }

      %DurableTimer{}
      |> DurableTimer.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc false
  def claim_due_timers(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 50)
    claimed_by = Keyword.get(opts, :claimed_by, owner_node())

    Repo.transaction(fn ->
      DurableTimer
      |> where([timer], timer.status == :pending and timer.fire_at <= ^now)
      |> order_by([timer], asc: timer.fire_at)
      |> limit(^limit)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> Repo.all()
      |> Enum.map(fn timer ->
        timer
        |> DurableTimer.changeset(%{
          status: :firing,
          claimed_at: now,
          claimed_by: claimed_by
        })
        |> Repo.update!()
      end)
    end)
  end

  @doc false
  def claim_timer(timer_id, opts \\ []) when is_binary(timer_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    claimed_by = Keyword.get(opts, :claimed_by, owner_node())

    Repo.transaction(fn ->
      case DurableTimer
           |> where([timer], timer.id == ^timer_id and timer.status == :pending)
           |> lock("FOR UPDATE")
           |> Repo.one() do
        nil ->
          Repo.rollback(:not_found)

        timer ->
          timer
          |> DurableTimer.changeset(%{
            status: :firing,
            claimed_at: now,
            claimed_by: claimed_by
          })
          |> Repo.update!()
      end
    end)
    |> case do
      {:ok, timer} -> {:ok, timer}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def recover_stale_timers(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    claim_ttl_ms = Keyword.get(opts, :claim_ttl_ms, 30_000)
    cutoff = DateTime.add(now, -claim_ttl_ms, :millisecond)

    {count, _rows} =
      DurableTimer
      |> where([timer], timer.status == :firing and timer.claimed_at < ^cutoff)
      |> Repo.update_all(
        set: [status: :pending, claimed_at: nil, claimed_by: nil, updated_at: now]
      )

    {:ok, count}
  end

  @doc false
  def release_timer_claim(timer_id) when is_binary(timer_id) do
    now = DateTime.utc_now()

    {count, _rows} =
      DurableTimer
      |> where([timer], timer.id == ^timer_id and timer.status == :firing)
      |> Repo.update_all(
        set: [status: :pending, claimed_at: nil, claimed_by: nil, updated_at: now]
      )

    case count do
      1 -> :ok
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def get_timer(timer_id) when is_binary(timer_id) do
    case Repo.get(DurableTimer, timer_id) do
      %DurableTimer{} = timer -> {:ok, timer}
      nil -> {:error, :not_found}
    end
  end

  @doc false
  def mark_timer_fired(timer_id) when is_binary(timer_id) do
    now = DateTime.utc_now()

    {count, _rows} =
      DurableTimer
      |> where([timer], timer.id == ^timer_id and timer.status == :firing)
      |> Repo.update_all(set: [status: :fired, updated_at: now])

    case count do
      1 ->
        :ok

      _ ->
        case Repo.get(DurableTimer, timer_id) do
          %DurableTimer{status: :fired} -> :ok
          _ -> {:error, :not_found}
        end
    end
  end

  @doc false
  def run_has_pending_timers?(run_id) when is_binary(run_id) do
    DurableTimer
    |> where([timer], timer.run_id == ^run_id and timer.status in ^[:pending, :firing])
    |> Repo.exists?()
  end

  @doc false
  def sleep_run(run_id) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      case run.status do
        :running ->
          run
          |> WorkflowRun.transition_status(:sleeping)
          |> Repo.update()

        :sleeping ->
          {:ok, run}

        _ ->
          {:error, :invalid_transition}
      end
    end
  end

  @doc false
  def resume_run(run_id) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      case run.status do
        :running ->
          {:ok, run}

        status when status in [:sleeping, :passivated] ->
          run
          |> WorkflowRun.transition_status(:running)
          |> Repo.update()

        _ ->
          {:error, :invalid_transition}
      end
    end
  end

  @doc false
  def create_signal_inbox(run_id, signal_id, signal_name, payload)
      when is_binary(run_id) and is_binary(signal_id) and is_binary(signal_name) do
    with {:ok, run} <- fetch_run(run_id) do
      attrs = %{
        run_id: run.id,
        signal_id: signal_id,
        signal_name: signal_name,
        payload: normalize_payload(payload) || %{},
        status: :pending,
        project_id: run.project_id,
        workos_organization_id: run.workos_organization_id
      }

      %SignalInbox{}
      |> SignalInbox.changeset(attrs)
      |> Repo.insert(
        on_conflict: [set: [signal_id: signal_id]],
        conflict_target: [:run_id, :signal_id],
        returning: true
      )
    end
  end

  @doc false
  def claim_pending_signals(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 50)
    claimed_by = Keyword.get(opts, :claimed_by, owner_node())

    Repo.transaction(fn ->
      SignalInbox
      |> where([signal], signal.status == :pending)
      |> order_by([signal], asc: signal.inserted_at)
      |> limit(^limit)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> Repo.all()
      |> Enum.map(fn signal ->
        signal
        |> SignalInbox.changeset(%{
          status: :delivering,
          claimed_at: now,
          claimed_by: claimed_by
        })
        |> Repo.update!()
      end)
    end)
  end

  @doc false
  def claim_signal(signal_id, opts \\ []) when is_binary(signal_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    claimed_by = Keyword.get(opts, :claimed_by, owner_node())

    Repo.transaction(fn ->
      case SignalInbox
           |> where([signal], signal.id == ^signal_id and signal.status == :pending)
           |> lock("FOR UPDATE SKIP LOCKED")
           |> Repo.one() do
        nil ->
          Repo.rollback(:not_found)

        %SignalInbox{} = signal ->
          signal
          |> SignalInbox.changeset(%{
            status: :delivering,
            claimed_at: now,
            claimed_by: claimed_by
          })
          |> Repo.update!()
      end
    end)
    |> case do
      {:ok, signal} -> {:ok, signal}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def recover_stale_signals(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    claim_ttl_ms = Keyword.get(opts, :claim_ttl_ms, 30_000)
    cutoff = DateTime.add(now, -claim_ttl_ms, :millisecond)

    {count, _rows} =
      SignalInbox
      |> where([signal], signal.status == :delivering and signal.claimed_at < ^cutoff)
      |> Repo.update_all(
        set: [status: :pending, claimed_at: nil, claimed_by: nil, updated_at: now]
      )

    {:ok, count}
  end

  @doc false
  def release_signal_claim(signal_id) when is_binary(signal_id) do
    now = DateTime.utc_now()

    {count, _rows} =
      SignalInbox
      |> where([signal], signal.id == ^signal_id and signal.status == :delivering)
      |> Repo.update_all(
        set: [status: :pending, claimed_at: nil, claimed_by: nil, updated_at: now]
      )

    case count do
      1 -> :ok
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def get_signal(signal_id) when is_binary(signal_id) do
    case Repo.get(SignalInbox, signal_id) do
      %SignalInbox{} = signal -> {:ok, signal}
      nil -> {:error, :not_found}
    end
  end

  @doc false
  def mark_signal_delivered(signal_id) when is_binary(signal_id) do
    now = DateTime.utc_now()

    {count, _rows} =
      SignalInbox
      |> where([signal], signal.id == ^signal_id and signal.status in ^[:pending, :delivering])
      |> Repo.update_all(
        set: [
          status: :delivered,
          delivered_at: now,
          claimed_at: nil,
          claimed_by: nil,
          updated_at: now
        ]
      )

    case count do
      1 -> :ok
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def mark_signal_skipped(signal_id) when is_binary(signal_id) do
    now = DateTime.utc_now()

    {count, _rows} =
      SignalInbox
      |> where([signal], signal.id == ^signal_id and signal.status in ^[:pending, :delivering])
      |> Repo.update_all(
        set: [
          status: :skipped,
          delivered_at: now,
          claimed_at: nil,
          claimed_by: nil,
          updated_at: now
        ]
      )

    case count do
      1 -> :ok
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def deliver_run_event(run_id, event, opts \\ []) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      case WorkflowRun.terminal?(run) do
        true ->
          {:ok, :skipped}

        false ->
          with {:ok, pid} <- ensure_run_worker(run, opts),
               :ok <- Worker.deliver_event(pid, event) do
            :ok
          end
      end
    end
  end

  @doc false
  def touch_run_activity(run_id) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      run
      |> WorkflowRun.touch_last_active()
      |> Repo.update()
    end
  end

  @doc false
  def complete_run(run_id, output) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      case run.status do
        :completed ->
          {:ok, run}

        _ ->
          run
          |> WorkflowRun.transition_status(:completed)
          |> Ecto.Changeset.change(output: normalize_payload(output), error: nil)
          |> Repo.update()
          |> tap(fn
            {:ok, completed_run} -> :ok = cancel_pending_timers(completed_run.id)
            _ -> :ok
          end)
      end
    end
  end

  @doc false
  def fail_run(run_id, reason) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      case run.status do
        :failed ->
          {:ok, run}

        _ ->
          run
          |> WorkflowRun.transition_status(:failed)
          |> Ecto.Changeset.change(error: normalize_payload(reason))
          |> Repo.update()
          |> tap(fn
            {:ok, failed_run} -> :ok = cancel_pending_timers(failed_run.id)
            _ -> :ok
          end)
      end
    end
  end

  @doc false
  def passivate_run(run_id) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      case run.status do
        :passivated ->
          {:ok, run}

        _ ->
          run
          |> WorkflowRun.transition_status(:passivated)
          |> Repo.update()
      end
    end
  end

  @doc false
  def list_passivation_candidates(%DateTime{} = idle_before, limit \\ 50) do
    from(run in WorkflowRun,
      where: run.status in ^[:running, :sleeping] and run.last_active_at < ^idle_before,
      order_by: [asc: run.last_active_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc false
  def release_run_lease(run_id) when is_binary(run_id) do
    case Fizz.Workflows.LeaseManager.release(run_id) do
      :ok -> :ok
      {:error, :not_owner} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp fetch_definition(scope, %WorkflowDefinition{id: id}), do: fetch_definition(scope, id)

  defp fetch_definition(scope, id) when is_binary(id) do
    with {:ok, project} <- project_from_scope(scope) do
      definition =
        from(definition in WorkflowDefinition,
          where: definition.project_id == ^project.id and definition.id == ^id
        )
        |> Repo.one()

      case definition do
        %WorkflowDefinition{} = definition_record -> {:ok, definition_record}
        nil -> {:error, :definition_not_found}
      end
    end
  end

  defp fetch_version(scope, %WorkflowDefinitionVersion{id: id}), do: fetch_version(scope, id)

  defp fetch_version(scope, id) when is_binary(id) do
    with {:ok, project} <- project_from_scope(scope) do
      version =
        from(version in WorkflowDefinitionVersion,
          join: definition in assoc(version, :workflow_definition),
          where: definition.project_id == ^project.id and version.id == ^id
        )
        |> Repo.one()

      case version do
        %WorkflowDefinitionVersion{} = version_record -> {:ok, version_record}
        nil -> {:error, :version_not_found}
      end
    end
  end

  defp project_from_scope(%Scope{project: %Project{} = project}), do: {:ok, project}
  defp project_from_scope(_scope), do: {:error, :project_scope_required}

  defp user_id_from_scope(%Scope{user: %{id: user_id}}) when is_binary(user_id),
    do: {:ok, user_id}

  defp user_id_from_scope(_scope), do: {:error, :unauthenticated}

  defp run_user_id(scope, opts) do
    case Keyword.get(opts, :user_id) do
      user_id when is_binary(user_id) and user_id != "" -> {:ok, user_id}
      _ -> user_id_from_scope(scope)
    end
  end

  defp ensure_draft(%WorkflowDefinitionVersion{status: :draft}), do: :ok
  defp ensure_draft(%WorkflowDefinitionVersion{}), do: {:error, :not_a_draft}

  defp initial_draft_attrs(definition_id) do
    Map.merge(@default_snapshot_attrs, %{
      workflow_definition_id: definition_id,
      version: 1,
      status: :draft
    })
  end

  defp clone_draft_attrs(definition_id, published_version) do
    published_version
    |> snapshot_attrs()
    |> Map.merge(%{
      workflow_definition_id: definition_id,
      version: published_version.version + 1,
      status: :draft,
      compiled_hash: nil,
      published_at: nil,
      published_by_user_id: nil
    })
  end

  defp snapshot_attrs(version) do
    %{
      steps: Enum.map(version.steps, &embed_to_attrs/1),
      connections: Enum.map(version.connections, &embed_to_attrs/1),
      step_groups: Enum.map(version.step_groups, &embed_to_attrs/1),
      viewport: version.viewport || WorkflowDefinitionVersion.default_viewport(),
      settings: version.settings || %{}
    }
  end

  defp create_pending_run(scope, version_record, input, compiled_hash, opts) do
    with {:ok, project} <- project_from_scope(scope),
         {:ok, user_id} <- run_user_id(scope, opts) do
      now = DateTime.utc_now()

      run_attrs = %{
        user_id: user_id,
        workflow_definition_id: version_record.workflow_definition_id,
        workflow_definition_version_id: version_record.id,
        project_id: project.id,
        workos_organization_id: project.workos_organization_id,
        status: :pending,
        input: normalize_payload(input) || %{},
        last_active_at: now,
        compiled_hash: compiled_hash,
        triggered_by: normalize_triggered_by(Keyword.get(opts, :triggered_by))
      }

      Multi.new()
      |> Multi.insert(:run, WorkflowRun.changeset(%WorkflowRun{}, run_attrs))
      |> Multi.run(:lease, fn repo, %{run: run} ->
        insert_run_lease(repo, run.id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{run: run}} -> {:ok, run}
        {:error, _operation, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp do_start_run(scope, %WorkflowDefinitionVersion{} = version_record, input, opts) do
    version_record = SlotDefaults.normalize_version(version_record)

    with :ok <- ensure_ready_to_start(scope, version_record, opts),
         {:ok, workflow, compiled_hash} <- Compiler.compile(version_record) do
      case create_pending_run(scope, version_record, input, compiled_hash, opts) do
        {:ok, run} ->
          start_pending_run(scope, run, workflow, compiled_hash, input)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp ensure_ready_to_start(scope, %WorkflowDefinitionVersion{} = version_record, opts) do
    with :ok <- ensure_valid_slot_declarations(version_record),
         {:ok, user_id} <- run_user_id(scope, opts) do
      case Readiness.check(version_record, user_id, scope) do
        :ready -> :ok
        {:needs_bindings, descriptors} -> {:error, {:slot_bindings_required, descriptors}}
      end
    end
  end

  defp ensure_valid_slot_declarations(%WorkflowDefinitionVersion{} = version_record) do
    case PublishValidation.slot_declaration_issues(version_record.steps || []) do
      [] -> :ok
      issues -> {:error, {:invalid_slot_declarations, issues}}
    end
  end

  defp maybe_sync_trigger_registrations({:ok, %WorkflowDefinitionVersion{} = version} = ok) do
    case RegistrationManager.sync_on_publish(version) do
      :ok ->
        ok

      {:error, reason} ->
        Logger.error(
          "trigger registration sync failed after publish for version #{version.id}: #{inspect(reason)}"
        )

        ok
    end
  end

  defp maybe_sync_trigger_registrations(other), do: other

  defp normalize_triggered_by(nil), do: nil
  defp normalize_triggered_by(triggered_by) when is_map(triggered_by), do: triggered_by
  defp normalize_triggered_by(_triggered_by), do: nil

  defp start_pending_run(scope, run, workflow, compiled_hash, input) do
    with {:ok, fence_token} <- Fizz.Workflows.LeaseManager.acquire(run.id),
         {:ok, store_state} <- SqliteStore.init(run.id, store_opts(run, fence_token, [])),
         {:ok, running_run} <- transition_run_status(run.id, :running),
         run_context <-
           ContextBuilder.build_run_context(scope, %{running_run | compiled_hash: compiled_hash}),
         {:ok, pid} <-
           WorkerSupervisor.start_worker(
             Keyword.merge(
               [
                 run_id: run.id,
                 workflow: Workflow.put_run_context(workflow, run_context),
                 run_context: run_context,
                 store: store_state,
                 fence_token: fence_token,
                 checkpoint_strategy: checkpoint_strategy(),
                 max_concurrency: max_run_concurrency(),
                 task_supervisor_max_children: max_task_children(),
                 idle_timeout_ms: worker_idle_timeout_ms()
               ],
               worker_process_opts([])
             )
           ) do
      :ok = Worker.run(pid, input)
      {:ok, %{running_run | compiled_hash: compiled_hash}}
    else
      {:error, _reason} = error ->
        cleanup_failed_start(run.id, error)
        error
    end
  end

  defp maybe_filter_run_status(query, nil), do: query

  defp maybe_filter_run_status(query, statuses) do
    normalized_statuses =
      statuses
      |> List.wrap()
      |> Enum.map(&normalize_run_status/1)
      |> Enum.reject(&is_nil/1)

    case normalized_statuses do
      [] -> query
      values -> where(query, [run], run.status in ^values)
    end
  end

  defp maybe_filter_definition_id(query, nil), do: query

  defp maybe_filter_definition_id(query, definition_id) when is_binary(definition_id) do
    where(query, [run], run.workflow_definition_id == ^definition_id)
  end

  defp maybe_filter_definition_id(query, _definition_id), do: query

  defp transition_run_status(run_id, new_status, attrs \\ %{}) do
    with {:ok, run} <- fetch_run(run_id) do
      run
      |> WorkflowRun.transition_status(new_status)
      |> Ecto.Changeset.change(attrs)
      |> Repo.update()
    end
  end

  defp fetch_run(run_id) when is_binary(run_id) do
    case Repo.get(WorkflowRun, run_id) do
      %WorkflowRun{} = run -> {:ok, run}
      nil -> {:error, :run_not_found}
    end
  end

  defp insert_run_lease(repo, run_id) do
    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO workflow_run_leases (run_id, owner_node, fence_token, checkpoint_seq, lease_expiry)
      VALUES ($1, NULL, 0, 0, $2)
      """,
      [dump_uuid(run_id), DateTime.add(DateTime.utc_now(), -1, :second)]
    )
    |> case do
      {:ok, _result} -> {:ok, :inserted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_opts(run, fence_token, opts) do
    Keyword.merge(
      [
        org_id: run.workos_organization_id,
        project_id: run.project_id,
        fence_token: fence_token,
        repo: Repo
      ],
      Keyword.get(opts, :store_opts, [])
    )
  end

  defp maybe_restore_from_s3(run, opts) do
    test_store_opts = Keyword.get(opts, :store_opts, [])

    ls_opts =
      litestream_opts()
      |> Keyword.merge(
        org_id: run.workos_organization_id,
        project_id: run.project_id
      )
      |> Keyword.merge(Keyword.take(test_store_opts, [:data_dir]))

    local_path = LitestreamManager.local_path(run.id, ls_opts)

    if File.exists?(local_path) do
      :ok
    else
      case LitestreamManager.restore(run.id, ls_opts) do
        {:ok, _path} -> :ok
        {:error, :already_exists} -> :ok
        {:error, :missing_binary} -> :ok
        {:error, reason} -> {:error, {:s3_restore_failed, reason}}
      end
    end
  end

  defp litestream_opts do
    [
      data_dir: Application.get_env(:fizz, :workflow_data_dir, "priv/workflow_data"),
      s3_bucket: Application.get_env(:fizz, :litestream_s3_bucket),
      s3_prefix: Application.get_env(:fizz, :litestream_s3_prefix, "workflows"),
      aws_region: Application.get_env(:fizz, :litestream_aws_region, "us-east-1"),
      s3_endpoint: Application.get_env(:fizz, :litestream_s3_endpoint),
      s3_skip_verify: Application.get_env(:fizz, :litestream_s3_skip_verify, false)
    ]
  end

  defp checkpoint_strategy do
    Application.get_env(:fizz, __MODULE__, []) |> Keyword.get(:checkpoint_strategy, :every_cycle)
  end

  defp max_run_concurrency do
    workflow_opts = Application.get_env(:fizz, __MODULE__, [])

    global_task_limit = max_task_children(workflow_opts)
    default_run_limit = min(System.schedulers_online(), global_task_limit)

    Keyword.get(workflow_opts, :max_concurrency, default_run_limit)
  end

  defp max_task_children(workflow_opts \\ Application.get_env(:fizz, __MODULE__, [])) do
    Keyword.get(workflow_opts, :max_task_children, System.schedulers_online() * 4)
  end

  defp worker_idle_timeout_ms do
    Application.get_env(:fizz, __MODULE__, []) |> Keyword.get(:idle_timeout_ms, 60_000)
  end

  defp ensure_run_worker(run, opts) do
    case Worker.lookup(run.id, worker_lookup_opts(opts)) do
      nil -> start_run_worker(run, opts)
      pid -> {:ok, pid}
    end
  end

  defp start_run_worker(run, opts) do
    with {:ok, fence_token} <-
           Fizz.Workflows.LeaseManager.acquire(run.id, lease_manager_opts(opts)),
         :ok <- maybe_restore_from_s3(run, opts),
         {:ok, store_state} <- SqliteStore.init(run.id, store_opts(run, fence_token, opts)),
         {:ok, workflow} <- restore_workflow(run, store_state),
         run_context <- ContextBuilder.build_run_context(Keyword.get(opts, :scope), run),
         {:ok, pid} <-
           WorkerSupervisor.start_worker(
             Keyword.merge(
               [
                 run_id: run.id,
                 workflow: Workflow.put_run_context(workflow, run_context),
                 run_context: run_context,
                 store: store_state,
                 fence_token: fence_token,
                 checkpoint_strategy: checkpoint_strategy(),
                 max_concurrency: max_run_concurrency(),
                 task_supervisor_max_children: max_task_children(),
                 idle_timeout_ms: worker_idle_timeout_ms()
               ],
               worker_process_opts(opts)
             )
           ) do
      {:ok, pid}
    else
      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        _ = release_run_lease(run.id)

        case reason do
          {:already_started, pid} -> {:ok, pid}
          _ -> error
        end
    end
  end

  defp restore_workflow(run, store_state) do
    with {:ok, version} <- restore_version(run.workflow_definition_version_id),
         {:ok, compiled_workflow, _compiled_hash} <- Compiler.compile(version),
         {:ok, event_log} <- SqliteStore.load(run.id, store_state) do
      {:ok, Workflow.from_events(event_log, compiled_workflow)}
    else
      {:error, :not_found} -> {:error, :checkpoint_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_version(version_id) when is_binary(version_id) do
    case Repo.get(WorkflowDefinitionVersion, version_id) do
      %WorkflowDefinitionVersion{} = version -> {:ok, version}
      nil -> {:error, :version_not_found}
    end
  end

  defp worker_process_opts(opts) do
    opts
    |> Keyword.take([:registry, :task_supervisor, :supervisor])
  end

  defp worker_lookup_opts(opts) do
    opts
    |> Keyword.take([:registry])
  end

  defp lease_manager_opts(opts) do
    opts
    |> Keyword.take([:server])
  end

  defp cleanup_failed_start(run_id, reason) do
    :ok = maybe_stop_worker(run_id, persist: false)
    :ok = release_run_lease(run_id)

    case Repo.get(WorkflowRun, run_id) do
      %WorkflowRun{status: :pending} = run ->
        _ = Repo.delete(run)
        _ = delete_run_lease(run.id)
        :ok

      %WorkflowRun{} ->
        _ = fail_run(run_id, reason)
        :ok

      nil ->
        :ok
    end
  end

  defp init_run_store(run) do
    SqliteStore.init(run.id, store_opts(run, 0, []))
  end

  defp load_run_event_log(run, store_state) do
    case SqliteStore.load(run.id, store_state) do
      {:ok, event_log} -> {:ok, event_log}
      {:error, :not_found} -> {:error, :checkpoint_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_step_execution(run, version, event_log, store_state, step_execution_id) do
    run
    |> build_step_executions(version, event_log, store_state)
    |> Enum.find(&(&1.id == step_execution_id))
    |> case do
      nil -> {:error, :step_execution_not_found}
      step_execution -> {:ok, step_execution}
    end
  end

  defp build_step_executions(run, version, event_log, store_state) do
    step_type_by_id =
      Map.new(version.steps, fn %Step{id: step_id, type_id: type_id} -> {step_id, type_id} end)

    node_name_by_hash = node_name_by_hash(event_log)
    splitter_dispatch_by_runnable = splitter_dispatch_by_runnable(event_log, step_type_by_id)

    event_log
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {event, index}, acc ->
      reduce_step_execution_event(
        acc,
        event,
        index,
        run,
        step_type_by_id,
        node_name_by_hash,
        splitter_dispatch_by_runnable,
        store_state
      )
    end)
    |> Map.values()
    |> Enum.sort_by(&step_execution_sort_key/1)
  end

  defp reduce_step_execution_event(
         acc,
         %RunnableDispatched{} = event,
         index,
         run,
         step_type_by_id,
         _node_name_by_hash,
         _splitter_dispatch_by_runnable,
         _store_state
       ) do
    with {:ok, step_id} <- StepExecutionTrace.logical_step_id(event.node_name, step_type_by_id) do
      step_execution_id = step_execution_id(run.id, event.runnable_id, event.attempt)
      started_at = approximate_event_time(run, index)
      iteration = StepExecutionTrace.fact_iteration_metadata(event.input_fact)

      Map.put(acc, step_execution_id, %{
        id: step_execution_id,
        execution_id: run.id,
        step_id: step_id,
        step_type_id: Map.get(step_type_by_id, step_id, "unknown"),
        status: "running",
        input_data: fact_value(event.input_fact),
        output_data: nil,
        output_item_count: nil,
        item_index: iteration.item_index,
        items_total: iteration.items_total,
        error: nil,
        attempt: event.attempt,
        retry_of_id: nil,
        duration_us: nil,
        queued_at: encode_datetime(started_at),
        started_at: encode_datetime(started_at),
        completed_at: nil,
        metadata: %{
          input_fact_hash: fact_hash(event.input_fact),
          output_fact_hash: nil,
          output_summary: nil
        },
        inserted_at: encode_datetime(started_at)
      })
    else
      :error -> acc
    end
  end

  defp reduce_step_execution_event(
         acc,
         %RunnableCompleted{} = event,
         index,
         run,
         step_type_by_id,
         node_name_by_hash,
         splitter_dispatch_by_runnable,
         store_state
       ) do
    case splitter_fan_out_step_id(event, node_name_by_hash, step_type_by_id) do
      {:ok, step_id} ->
        build_splitter_iteration_executions(
          acc,
          event,
          index,
          run,
          step_id,
          splitter_dispatch_by_runnable,
          store_state
        )

      :error ->
        step_execution_id = step_execution_id(run.id, event.runnable_id, event.attempt)
        existing = Map.get(acc, step_execution_id)

        with {:ok, step_id} <-
               completed_step_id(existing, event, node_name_by_hash, step_type_by_id) do
          input_fact_hash = existing_input_fact_hash(existing, event)
          output = fact_value(event.result_fact)
          completed_at = approximate_event_time(run, index)

          started_at =
            existing_timestamp(existing, :started_at, approximate_event_time(run, index))

          iteration = completed_iteration_metadata(existing, event.result_fact)

          Map.put(acc, step_execution_id, %{
            id: step_execution_id,
            execution_id: run.id,
            step_id: step_id,
            step_type_id: Map.get(step_type_by_id, step_id, "unknown"),
            status: "completed",
            input_data: existing_input_data(existing, input_fact_hash, store_state),
            output_data: output,
            output_item_count: output_item_count(output),
            item_index: iteration.item_index,
            items_total: iteration.items_total,
            error: nil,
            attempt: event.attempt,
            retry_of_id: nil,
            duration_us: event_duration_us(event),
            queued_at: existing_timestamp(existing, :queued_at, started_at),
            started_at: encode_datetime(started_at),
            completed_at: encode_datetime(completed_at),
            metadata: %{
              input_fact_hash: input_fact_hash,
              output_fact_hash: fact_hash(event.result_fact),
              output_summary: truncate_output(output)
            },
            inserted_at: existing_timestamp(existing, :inserted_at, started_at)
          })
        else
          :error -> acc
        end
    end
  end

  defp reduce_step_execution_event(
         acc,
         %RunnableFailed{} = event,
         index,
         run,
         step_type_by_id,
         node_name_by_hash,
         _splitter_dispatch_by_runnable,
         store_state
       ) do
    step_execution_id = step_execution_id(run.id, event.runnable_id, event.attempts - 1)
    existing = Map.get(acc, step_execution_id)

    with {:ok, step_id} <- failed_step_id(existing, event, node_name_by_hash, step_type_by_id) do
      started_at = existing_timestamp(existing, :started_at, approximate_event_time(run, index))
      input_fact_hash = existing_input_fact_hash(existing, nil)
      iteration = existing_iteration_metadata(existing)

      Map.put(acc, step_execution_id, %{
        id: step_execution_id,
        execution_id: run.id,
        step_id: step_id,
        step_type_id: Map.get(step_type_by_id, step_id, "unknown"),
        status: "failed",
        input_data: existing_input_data(existing, input_fact_hash, store_state),
        output_data: Map.get(existing || %{}, :output_data),
        output_item_count: nil,
        item_index: iteration.item_index,
        items_total: iteration.items_total,
        error: inspect(event.error),
        attempt: max(event.attempts - 1, 0),
        retry_of_id: nil,
        duration_us: event_duration_us(event) || Map.get(existing || %{}, :duration_us),
        queued_at: existing_timestamp(existing, :queued_at, started_at),
        started_at: encode_datetime(started_at),
        completed_at: encode_datetime(approximate_event_time(run, index)),
        metadata: Map.get(existing || %{}, :metadata, %{input_fact_hash: input_fact_hash}),
        inserted_at: existing_timestamp(existing, :inserted_at, started_at)
      })
    else
      :error -> acc
    end
  end

  defp reduce_step_execution_event(
         acc,
         _event,
         _index,
         _run,
         _step_type_by_id,
         _node_name_by_hash,
         _splitter_dispatch_by_runnable,
         _store_state
       ),
       do: acc

  defp node_name_by_hash(event_log) do
    Enum.reduce(event_log, %{}, fn
      %ComponentAdded{hash: hash, name: name}, acc when not is_nil(hash) and not is_nil(name) ->
        Map.put(acc, hash, name)

      %RunnableDispatched{node_hash: hash, node_name: name}, acc
      when not is_nil(hash) and not is_nil(name) ->
        Map.put(acc, hash, name)

      _event, acc ->
        acc
    end)
  end

  defp splitter_dispatch_by_runnable(event_log, step_type_by_id) do
    Enum.reduce(event_log, %{}, fn
      %RunnableDispatched{} = event, acc ->
        case StepExecutionTrace.splitter_fan_out_step_id(event.node_name, step_type_by_id) do
          {:ok, _step_id} ->
            Map.put(acc, {event.runnable_id, event.attempt}, %{
              input_data: fact_value(event.input_fact),
              input_fact_hash: fact_hash(event.input_fact)
            })

          :error ->
            acc
        end

      _event, acc ->
        acc
    end)
  end

  defp completed_step_id(existing, event, node_name_by_hash, step_type_by_id) do
    case existing do
      %{step_id: step_id} when is_binary(step_id) ->
        {:ok, step_id}

      _ ->
        event.node_hash
        |> then(&Map.get(node_name_by_hash, &1))
        |> StepExecutionTrace.logical_step_id(step_type_by_id)
    end
  end

  defp failed_step_id(existing, event, node_name_by_hash, step_type_by_id) do
    case existing do
      %{step_id: step_id} when is_binary(step_id) ->
        {:ok, step_id}

      _ ->
        event.node_hash
        |> then(&Map.get(node_name_by_hash, &1))
        |> StepExecutionTrace.logical_step_id(step_type_by_id)
    end
  end

  defp step_execution_id(run_id, runnable_id, attempt) do
    "#{run_id}:#{runnable_id}:#{attempt}"
  end

  defp approximate_event_time(run, index) do
    base_time = run.started_at || run.inserted_at || DateTime.utc_now()
    DateTime.add(base_time, index, :microsecond)
  end

  defp existing_timestamp(nil, _field, %DateTime{} = fallback), do: encode_datetime(fallback)
  defp existing_timestamp(nil, _field, fallback), do: encode_datetime(fallback)

  defp existing_timestamp(existing, field, %DateTime{} = fallback) do
    Map.get(existing, field) || encode_datetime(fallback)
  end

  defp existing_timestamp(existing, field, fallback) do
    Map.get(existing, field) || encode_datetime(fallback)
  end

  defp existing_input_fact_hash(%{metadata: metadata}, _event) when is_map(metadata) do
    Map.get(metadata, :input_fact_hash)
  end

  defp existing_input_fact_hash(_existing, %RunnableCompleted{result_fact: result_fact}) do
    fact_parent_hash(result_fact)
  end

  defp existing_input_fact_hash(_existing, _event), do: nil

  defp existing_input_data(%{input_data: input_data}, _input_fact_hash, _store_state)
       when not is_nil(input_data),
       do: input_data

  defp existing_input_data(_existing, input_fact_hash, store_state) do
    load_fact_value(input_fact_hash, store_state, nil)
  end

  defp load_fact_value(nil, _store_state, fallback), do: fallback

  defp load_fact_value(hash, store_state, fallback) when not is_nil(hash) do
    case SqliteStore.load_fact(hash, store_state) do
      {:ok, value} -> value
      {:error, _reason} -> fallback
    end
  end

  defp load_fact_value(_hash, _store_state, fallback), do: fallback

  defp fact_hash(%{hash: hash}) when not is_nil(hash), do: hash
  defp fact_hash(_fact), do: nil

  defp fact_value(%{value: value}), do: value
  defp fact_value(_fact), do: nil

  defp output_item_count(nil), do: nil
  defp output_item_count(output) when is_list(output), do: length(output)
  defp output_item_count(_output), do: 1

  defp splitter_fan_out_step_id(
         %RunnableCompleted{node_hash: node_hash},
         node_name_by_hash,
         step_type_by_id
       ) do
    node_hash
    |> then(&Map.get(node_name_by_hash, &1))
    |> StepExecutionTrace.splitter_fan_out_step_id(step_type_by_id)
  end

  defp build_splitter_iteration_executions(
         acc,
         event,
         index,
         run,
         step_id,
         splitter_dispatch_by_runnable,
         store_state
       ) do
    completed_at = approximate_event_time(run, index)
    emitted_facts = splitter_emitted_facts(event.result_fact)
    items_total = length(emitted_facts)
    per_item_duration = per_item_duration_us(event_duration_us(event), items_total)
    dispatch = Map.get(splitter_dispatch_by_runnable, {event.runnable_id, event.attempt}, %{})

    Enum.reduce(Enum.with_index(emitted_facts), acc, fn {fact, fallback_index}, acc ->
      item_index = StepExecutionTrace.fact_item_index(fact) || fallback_index

      step_execution_id =
        step_execution_id(run.id, "#{event.runnable_id}:#{item_index}", event.attempt)

      input_fact_hash =
        Map.get(dispatch, :input_fact_hash) || fan_out_input_fact_hash(fact)

      input_data =
        Map.get(dispatch, :input_data) || load_fact_value(input_fact_hash, store_state, nil)

      started_at = DateTime.add(completed_at, -per_item_duration, :microsecond)

      Map.put(acc, step_execution_id, %{
        id: step_execution_id,
        execution_id: run.id,
        step_id: step_id,
        step_type_id: "splitter",
        status: "completed",
        input_data: input_data,
        output_data: fact_value(fact),
        output_item_count: 1,
        item_index: item_index,
        items_total: StepExecutionTrace.fact_items_total(fact) || items_total,
        error: nil,
        attempt: event.attempt,
        retry_of_id: nil,
        duration_us: per_item_duration,
        queued_at: encode_datetime(started_at),
        started_at: encode_datetime(started_at),
        completed_at: encode_datetime(completed_at),
        metadata: %{
          input_fact_hash: input_fact_hash,
          output_fact_hash: fact_hash(fact),
          output_summary: truncate_output(fact_value(fact))
        },
        inserted_at: encode_datetime(started_at)
      })
    end)
  end

  defp splitter_emitted_facts(result) when is_list(result) do
    Enum.filter(result, &match?(%Runic.Workflow.Fact{}, &1))
  end

  defp splitter_emitted_facts(_result), do: []

  defp fact_parent_hash(%{ancestry: {_node_hash, fact_hash}}) when not is_nil(fact_hash),
    do: fact_hash

  defp fact_parent_hash(_fact), do: nil

  defp fan_out_input_fact_hash(%{ancestry: {_fan_out_hash, input_fact_hash}})
       when not is_nil(input_fact_hash),
       do: input_fact_hash

  defp fan_out_input_fact_hash(_fact), do: nil

  defp completed_iteration_metadata(
         %{item_index: item_index, items_total: items_total},
         _result_fact
       ) do
    %{item_index: item_index, items_total: items_total}
  end

  defp completed_iteration_metadata(_existing, result_fact) do
    StepExecutionTrace.fact_iteration_metadata(result_fact)
  end

  defp existing_iteration_metadata(%{item_index: item_index, items_total: items_total}) do
    %{item_index: item_index, items_total: items_total}
  end

  defp existing_iteration_metadata(_existing) do
    %{item_index: nil, items_total: nil}
  end

  defp per_item_duration_us(duration_us, items_total)
       when is_integer(duration_us) and duration_us >= 0 and is_integer(items_total) and
              items_total > 0 do
    max(div(duration_us, items_total), 0)
  end

  defp per_item_duration_us(_duration_us, _items_total), do: 0

  defp duration_us_from_ms(duration_ms) when is_integer(duration_ms) and duration_ms >= 0,
    do: duration_ms * 1_000

  defp duration_us_from_ms(_duration_ms), do: nil

  defp event_duration_us(%RunnableCompleted{} = event) do
    case Map.get(event, :duration_us) do
      duration_us when is_integer(duration_us) and duration_us >= 0 ->
        duration_us

      _ ->
        duration_us_from_ms(event.duration_ms)
    end
  end

  defp event_duration_us(%RunnableFailed{} = event) do
    case Map.get(event, :duration_us) do
      duration_us when is_integer(duration_us) and duration_us >= 0 -> duration_us
      _ -> nil
    end
  end

  defp truncate_output(output) do
    rendered = inspect(output, pretty: true, limit: :infinity, printable_limit: :infinity)

    if byte_size(rendered) <= 1_024 do
      rendered
    else
      binary_part(rendered, 0, 1_024) <> "..."
    end
  end

  defp step_execution_sort_key(step_execution) do
    [
      Map.get(step_execution, :started_at),
      Map.get(step_execution, :completed_at),
      Map.get(step_execution, :inserted_at)
    ]
    |> Enum.find(&(is_binary(&1) and byte_size(&1) > 0))
    |> case do
      nil -> ""
      value -> value
    end
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_datetime(value), do: value

  defp broadcast_run_event(run_id, event) do
    Phoenix.PubSub.broadcast(Fizz.PubSub, "workflow_run:#{run_id}", event)
  end

  defp delete_run_lease(run_id) do
    Ecto.Adapters.SQL.query(
      Repo,
      "DELETE FROM workflow_run_leases WHERE run_id = $1",
      [dump_uuid(run_id)]
    )
  end

  defp maybe_stop_worker(run_id, opts) do
    case Worker.stop(run_id, opts) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp cancel_pending_timers(run_id) do
    now = DateTime.utc_now()

    _ =
      DurableTimer
      |> where([timer], timer.run_id == ^run_id and timer.status == :pending)
      |> Repo.update_all(set: [status: :cancelled, updated_at: now])

    :ok
  end

  defp latest_draft_version(definition_id) do
    from(version in WorkflowDefinitionVersion,
      where: version.workflow_definition_id == ^definition_id and version.status == :draft,
      order_by: [desc: version.version],
      limit: 1
    )
    |> Repo.one()
  end

  defp latest_published_version(definition_id) do
    from(version in WorkflowDefinitionVersion,
      where: version.workflow_definition_id == ^definition_id and version.status == :published,
      order_by: [desc: version.version],
      limit: 1
    )
    |> Repo.one()
  end

  defp normalize_snapshot_attrs(attrs) when is_map(attrs) do
    attrs
    |> put_default_if_missing(:steps, [])
    |> put_default_if_missing(:connections, [])
    |> put_default_if_missing(:step_groups, [])
    |> put_default_if_missing(:viewport, WorkflowDefinitionVersion.default_viewport())
    |> put_default_if_missing(:settings, %{})
    |> SlotDefaults.normalize_snapshot_attrs()
  end

  defp put_default_if_missing(attrs, field, default) do
    field_name = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) -> attrs
      Map.has_key?(attrs, field_name) -> attrs
      true -> Map.put(attrs, field, default)
    end
  end

  defp embed_to_attrs(%_{} = embed), do: Map.from_struct(embed)
  defp embed_to_attrs(embed) when is_map(embed), do: embed

  defp provisional_compiled_hash do
    String.duplicate("0", 64)
  end

  defp add_compile_errors(changeset, errors) do
    Enum.reduce(errors, changeset, fn error, acc ->
      Ecto.Changeset.add_error(acc, :steps, error.message)
    end)
  end

  defp normalize_payload(nil), do: nil

  defp normalize_payload(value) when is_map(value) do
    normalize_json(value)
  end

  defp normalize_payload(value) do
    %{"value" => normalize_json(value)}
  end

  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp normalize_json(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), normalize_json(nested_value)} end)
  end

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp normalize_json(nil), do: nil
  defp normalize_json(value), do: inspect(value)

  defp normalize_run_status(status) when status in @run_statuses, do: status

  defp normalize_run_status(status) when is_binary(status) do
    status
    |> String.trim()
    |> case do
      "" -> nil
      value -> String.to_existing_atom(value)
    end
  rescue
    ArgumentError -> nil
  end

  defp normalize_run_status(_status), do: nil

  defp owner_node do
    Atom.to_string(node())
  end

  defp dump_uuid(run_id), do: Ecto.UUID.dump!(run_id)
end
