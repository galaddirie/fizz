defmodule Fizz.Workflows.Runtime.Runs do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias Fizz.Accounts.{Project, Scope}
  alias Fizz.Repo
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.PublishValidation
  alias Fizz.Workflows.Readiness
  alias Fizz.Workflows.Runner.{Worker, WorkerSupervisor}
  alias Fizz.Workflows.Runtime.{ContextBuilder, Payloads, Timers}
  alias Fizz.Workflows.Store.{LitestreamManager, Options, SqliteStore}

  alias Fizz.Workflows.{
    CredentialDefaults,
    WorkflowDefinitionVersion,
    WorkflowRun
  }

  alias Runic.Workflow

  @run_statuses WorkflowRun.statuses()
  @run_status_by_string @run_statuses
                        |> Enum.map(fn status -> {Atom.to_string(status), status} end)
                        |> Map.new()
  @workflow_config_module Fizz.Workflows
  @default_delivery_timeout_ms 30_000

  def start_run(scope, %WorkflowDefinitionVersion{} = version_record, input, opts) do
    version_record = CredentialDefaults.normalize_version(version_record)

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

  def cancel_run(scope, run_id) when is_binary(run_id) do
    with {:ok, run} <- get_run(scope, run_id),
         :ok <- maybe_stop_worker(run.id, persist: true),
         {:ok, cancelled_run} <- finalize_terminal_run(run.id, :cancelled) do
      {:ok, cancelled_run}
    end
  end

  def signal_run(scope, run_id, signal_name, payload, signal_id) do
    with {:ok, run} <- get_run(scope, run_id) do
      Fizz.Workflows.SignalRouter.accept_signal(
        run.id,
        signal_id,
        signal_name,
        payload,
        signal_router_delivery_opts()
      )
    end
  end

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

  def resume_run(run_id) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      case run.status do
        :running ->
          do_clear_run_error(run)

        status when status in [:sleeping, :passivated] ->
          run
          |> WorkflowRun.transition_status(:running)
          |> Ecto.Changeset.change(error: nil)
          |> Repo.update()

        _ ->
          {:error, :invalid_transition}
      end
    end
  end

  def record_run_retry(run_id, error_payload, opts \\ []) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id),
         {:ok, changeset} <- retry_changeset(run, error_payload, Keyword.get(opts, :sleep?)) do
      Repo.update(changeset)
    end
  end

  def clear_run_error(run_id) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      do_clear_run_error(run)
    end
  end

  def deliver_run_event(run_id, event, opts \\ []) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      case WorkflowRun.terminal?(run) do
        true ->
          {:ok, :skipped}

        false ->
          with {:ok, pid} <- ensure_run_worker(run, opts),
               {:ok, delivery_result} <-
                 Worker.deliver_event(pid, event, timeout: delivery_timeout_ms(opts)) do
            normalize_run_event_delivery(delivery_result)
          end
      end
    end
  end

  def touch_run_activity(run_id) when is_binary(run_id) do
    with {:ok, run} <- fetch_run(run_id) do
      run
      |> WorkflowRun.touch_last_active()
      |> Repo.update()
    end
  end

  def complete_run(run_id, output) when is_binary(run_id) do
    finalize_terminal_run(run_id, :completed, %{output: Payloads.normalize(output), error: nil})
  end

  def fail_run(run_id, reason) when is_binary(run_id) do
    finalize_terminal_run(run_id, :failed, %{error: Payloads.normalize(reason)})
  end

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

  def list_passivation_candidates(%DateTime{} = idle_before, limit \\ 50) do
    from(run in WorkflowRun,
      where: run.status in ^[:running, :sleeping] and run.last_active_at < ^idle_before,
      order_by: [asc: run.last_active_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def release_run_lease(run_id) when is_binary(run_id) do
    case Fizz.Workflows.LeaseManager.release(run_id) do
      :ok -> :ok
      {:error, :not_owner} -> :ok
      {:error, _reason} -> :ok
    end
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
        input: Payloads.normalize(input) || %{},
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

  defp ensure_ready_to_start(scope, %WorkflowDefinitionVersion{} = version_record, opts) do
    with :ok <- ensure_valid_credential_declarations(version_record),
         {:ok, user_id} <- run_user_id(scope, opts) do
      case Readiness.check(version_record, user_id, scope) do
        :ready -> :ok
        {:needs_bindings, descriptors} -> {:error, {:credential_bindings_required, descriptors}}
      end
    end
  end

  defp ensure_valid_credential_declarations(%WorkflowDefinitionVersion{} = version_record) do
    case PublishValidation.credential_declaration_issues(version_record.steps || []) do
      [] -> :ok
      issues -> {:error, {:invalid_credential_declarations, issues}}
    end
  end

  defp normalize_triggered_by(nil), do: nil
  defp normalize_triggered_by(triggered_by) when is_map(triggered_by), do: triggered_by
  defp normalize_triggered_by(_triggered_by), do: nil

  defp start_pending_run(scope, run, workflow, compiled_hash, input) do
    with {:ok, fence_token} <- Fizz.Workflows.LeaseManager.acquire(run.id),
         {:ok, store_state} <- SqliteStore.init(run.id, Options.for_run(run, fence_token)),
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

  defp finalize_terminal_run(run_id, status, attrs \\ %{}) do
    with {:ok, run} <- fetch_run(run_id),
         {:ok, finalized_run, status_changed?} <- apply_terminal_status(run, status, attrs) do
      :ok = Timers.cancel_pending_timers(finalized_run.id)
      :ok = release_run_lease(finalized_run.id)
      :ok = maybe_broadcast_terminal_status(finalized_run.id, status, status_changed?)

      {:ok, finalized_run}
    end
  end

  defp apply_terminal_status(%WorkflowRun{status: status} = run, status, _attrs) do
    {:ok, run, false}
  end

  defp apply_terminal_status(%WorkflowRun{} = run, status, attrs) do
    run
    |> WorkflowRun.transition_status(status)
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
    |> case do
      {:ok, finalized_run} -> {:ok, finalized_run, true}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_broadcast_terminal_status(run_id, status, true) do
    _ =
      broadcast_run_event(
        run_id,
        {:run_status_changed, %{run_id: run_id, status: status, timestamp: DateTime.utc_now()}}
      )

    :ok
  end

  defp maybe_broadcast_terminal_status(_run_id, _status, false), do: :ok

  defp retry_changeset(%WorkflowRun{status: :running} = run, error_payload, true) do
    changeset =
      run
      |> WorkflowRun.transition_status(:sleeping)
      |> Ecto.Changeset.change(
        error: Payloads.normalize(error_payload),
        last_active_at: DateTime.utc_now()
      )

    {:ok, changeset}
  end

  defp retry_changeset(%WorkflowRun{} = run, error_payload, _sleep?) do
    if WorkflowRun.terminal?(run) do
      {:error, :invalid_transition}
    else
      {:ok,
       Ecto.Changeset.change(run,
         error: Payloads.normalize(error_payload),
         last_active_at: DateTime.utc_now()
       )}
    end
  end

  defp do_clear_run_error(%WorkflowRun{error: nil} = run), do: {:ok, run}

  defp do_clear_run_error(%WorkflowRun{} = run) do
    run
    |> Ecto.Changeset.change(error: nil)
    |> Repo.update()
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
      VALUES ($1, NULL, 0, 0, NOW() - interval '1 second')
      """,
      [dump_uuid(run_id)]
    )
    |> case do
      {:ok, _result} -> {:ok, :inserted}
      {:error, reason} -> {:error, reason}
    end
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
    workflow_opts()
    |> Keyword.get(:checkpoint_strategy, :every_cycle)
  end

  defp max_run_concurrency do
    opts = workflow_opts()

    global_task_limit = max_task_children(opts)
    default_run_limit = min(System.schedulers_online(), global_task_limit)

    Keyword.get(opts, :max_concurrency, default_run_limit)
  end

  defp max_task_children(opts) do
    Keyword.get(opts, :max_task_children, System.schedulers_online() * 4)
  end

  defp worker_idle_timeout_ms do
    workflow_opts()
    |> Keyword.get(:idle_timeout_ms, 60_000)
  end

  defp delivery_timeout_ms(opts) do
    config = workflow_opts()

    opts
    |> Keyword.get(:delivery_timeout_ms, Keyword.get(opts, :timeout))
    |> case do
      nil -> Keyword.get(config, :delivery_timeout_ms, @default_delivery_timeout_ms)
      timeout -> timeout
    end
  end

  defp workflow_opts do
    Application.get_env(:fizz, @workflow_config_module, [])
  end

  defp normalize_run_event_delivery(:settled), do: :ok
  defp normalize_run_event_delivery(:skipped), do: {:ok, :skipped}
  defp normalize_run_event_delivery(:accepted), do: {:ok, :accepted}

  defp signal_router_delivery_opts do
    case Process.whereis(Fizz.Workflows.SignalRouter) do
      nil -> []
      _pid -> [server: Fizz.Workflows.SignalRouter]
    end
  end

  defp ensure_run_worker(run, opts) do
    case Worker.lookup(run.id, worker_lookup_opts(opts)) do
      nil -> start_run_worker(run, opts)
      pid -> {:ok, pid}
    end
  end

  defp start_run_worker(run, opts) do
    registry = Keyword.get(opts, :registry, Fizz.Workflows.Runner.Registry)
    start_key = {:starting_worker, run.id}

    case Registry.register(registry, start_key, nil) do
      {:ok, _owner} ->
        try do
          do_start_run_worker(run, opts)
        after
          Registry.unregister(registry, start_key)
        end

      {:error, {:already_registered, _pid}} ->
        await_run_worker(run, opts, start_key)
    end
  end

  defp do_start_run_worker(run, opts) do
    with {:ok, fence_token} <-
           Fizz.Workflows.LeaseManager.acquire(run.id, lease_manager_opts(opts)),
         :ok <- maybe_restore_from_s3(run, opts),
         {:ok, store_state} <- SqliteStore.init(run.id, Options.for_run(run, fence_token, opts)),
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

  defp await_run_worker(run, opts, start_key, attempts \\ 100)

  defp await_run_worker(run, opts, _start_key, attempts) when attempts <= 0 do
    start_run_worker(run, opts)
  end

  defp await_run_worker(run, opts, start_key, attempts) do
    registry = Keyword.get(opts, :registry, Fizz.Workflows.Runner.Registry)

    case Worker.lookup(run.id, worker_lookup_opts(opts)) do
      nil ->
        case Registry.lookup(registry, start_key) do
          [] ->
            start_run_worker(run, opts)

          _starting ->
            receive do
            after
              10 -> await_run_worker(run, opts, start_key, attempts - 1)
            end
        end

      pid ->
        {:ok, pid}
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
    |> Keyword.take([:registry, :runnable_dispatcher, :supervisor])
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

  defp normalize_run_status(status) when status in @run_statuses, do: status

  defp normalize_run_status(status) when is_binary(status) do
    status
    |> String.trim()
    |> case do
      "" -> nil
      value -> Map.get(@run_status_by_string, value)
    end
  end

  defp normalize_run_status(_status), do: nil

  defp dump_uuid(run_id), do: Ecto.UUID.dump!(run_id)
end
