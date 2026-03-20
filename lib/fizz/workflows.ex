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
  alias Fizz.Triggers.RegistrationManager
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.Runner.{Worker, WorkerSupervisor}
  alias Fizz.Workflows.Runtime.ContextBuilder
  alias Fizz.Workflows.Store.SqliteStore

  alias Fizz.Workflows.{
    DurableTimer,
    SignalInbox,
    WorkflowDefinition,
    WorkflowDefinitionVersion,
    WorkflowRun
  }

  alias Runic.Workflow

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
      published_at = DateTime.utc_now()

      changeset =
        WorkflowDefinitionVersion.publish_changeset(version_record, %{
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
  def start_run(scope, version, input, opts \\ []) do
    with {:ok, version_record} <- fetch_version(scope, version),
         {:ok, workflow, compiled_hash} <- Compiler.compile(version_record) do
      case create_pending_run(scope, version_record, input, compiled_hash, opts) do
        {:ok, run} ->
          start_pending_run(scope, run, workflow, compiled_hash, input)

        {:error, _reason} = error ->
          error
      end
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
  def list_pending_signal_ids(limit \\ 50) do
    SignalInbox
    |> where([signal], signal.status == :pending)
    |> order_by([signal], asc: signal.inserted_at)
    |> limit(^limit)
    |> select([signal], signal.id)
    |> Repo.all()
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
      |> where([signal], signal.id == ^signal_id and signal.status == :pending)
      |> Repo.update_all(set: [status: :delivered, delivered_at: now, updated_at: now])

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
      |> where([signal], signal.id == ^signal_id and signal.status == :pending)
      |> Repo.update_all(set: [status: :skipped, delivered_at: now, updated_at: now])

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
  def list_passivation_candidates(%DateTime{} = idle_before) do
    from(run in WorkflowRun,
      where: run.status in ^[:running, :sleeping] and run.last_active_at < ^idle_before,
      order_by: [asc: run.last_active_at]
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
    with {:ok, project} <- project_from_scope(scope) do
      now = DateTime.utc_now()

      run_attrs = %{
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

  defp checkpoint_strategy do
    Application.get_env(:fizz, __MODULE__, []) |> Keyword.get(:checkpoint_strategy, :every_cycle)
  end

  defp max_run_concurrency do
    Application.get_env(:fizz, __MODULE__, [])
    |> Keyword.get(:max_concurrency, System.schedulers_online())
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
    case SqliteStore.load(run.id, store_state) do
      {:ok, event_log} ->
        {:ok, Workflow.from_events(event_log)}

      {:error, :not_found} ->
        {:error, :checkpoint_not_found}

      {:error, reason} ->
        {:error, reason}
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
