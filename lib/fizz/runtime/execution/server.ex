defmodule Fizz.Runtime.Execution.Server do
  @moduledoc """
  OTP process representing a single workflow execution.
  Uses Runic as the core dataflow engine.
  """
  use GenServer, restart: :temporary

  require Logger
  alias Runic.Workflow
  alias Fizz.Runtime.RunicAdapter
  alias Fizz.Runtime.Events
  alias Fizz.Runtime.Hooks.Observability
  alias Fizz.Executions
  alias Fizz.Executions.Execution
  import Ecto.Query, warn: false
  alias Fizz.Repo

  defmodule State do
    defstruct [
      :execution_id,
      :runic_workflow,
      :status,
      :metadata,
      :runtime_opts,
      :trigger_data
    ]
  end

  # ============================================================================
  # API
  # ============================================================================

  def start_link(opts) do
    execution_id = Keyword.fetch!(opts, :execution_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(execution_id))
  end

  defp via_tuple(execution_id) do
    {:via, Registry, {Fizz.Runtime.Execution.Registry, execution_id}}
  end

  # ============================================================================
  # Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    execution_id = Keyword.fetch!(opts, :execution_id)
    runtime_opts = Keyword.drop(opts, [:execution_id])

    Logger.metadata(execution_id: execution_id)
    Logger.info("Initializing execution server")

    Process.flag(:trap_exit, true)

    try do
      case load_with_source(execution_id) do
        {:ok, execution} ->
          case build_runic_workflow(execution, runtime_opts) do
            {:ok, runic_wrk} ->
              state = %State{
                execution_id: execution_id,
                runic_workflow: runic_wrk,
                status: execution.status,
                metadata: execution.metadata,
                runtime_opts: runtime_opts,
                trigger_data: (execution.trigger && execution.trigger.data) || %{}
              }

              # Trigger execution if process was started for a pending/running execution
              case execution.status do
                s when s in [:pending, :running] ->
                  send(self(), :run)

                _ ->
                  :ok
              end

              {:ok, state}

            {:error, :missing_source} ->
              handle_init_failure(execution_id, :missing_source)
              {:stop, :missing_source}
          end

        {:error, :not_found} ->
          {:stop, :not_found}
      end
    rescue
      e ->
        Logger.error("Execution server failed to initialize: #{inspect(e)}",
          stacktrace: __STACKTRACE__
        )

        handle_init_failure(execution_id, e)
        {:stop, :init_failure}
    end
  end

  @impl true
  def terminate(reason, state) do
    # If the process is terminating abnormally and hasn't reached a terminal state
    # We ignore :normal, :shutdown, and {:shutdown, :normal}
    execution_id =
      case state do
        %State{execution_id: id} -> id
        _ -> nil
      end

    if (execution_id && reason not in [:normal, :shutdown]) and not match?({:shutdown, _}, reason) do
      case Repo.get(Execution, execution_id) do
        %Execution{status: status} = execution
        when status not in [:completed, :failed, :cancelled] ->
          Logger.error("Execution server terminating unexpectedly: #{inspect(reason)}")
          error_map = Execution.format_error(reason)

          execution
          |> Execution.changeset(%{
            status: :failed,
            error: error_map,
            completed_at: DateTime.utc_now()
          })
          |> Repo.update()

          Events.emit(:execution_failed, execution_id, %{status: :failed, error: error_map})

          # Also cancel any active steps
          Executions.cancel_active_step_executions(execution_id)

        _ ->
          :ok
      end
    end

    case state do
      %State{} when not is_nil(execution_id) ->
        :ok

      _ ->
        :ok
    end

    # Always flush buffered step events before dying
    flush_step_executions(execution_id)

    :ok
  end

  @impl true
  def handle_info(:run, state) do
    # Transition to running in DB if pending
    if state.status == :pending do
      update_status(state.execution_id, :running)
    end

    # Emit execution started event
    Events.emit(:execution_started, state.execution_id, %{status: :running})

    # Use cached trigger data from state
    trigger_data = state.trigger_data

    # Execute Runic cycles
    try do
      # For now, we run until completion or wait state.
      # Runic's react_until_satisfied is the primary driver.
      new_runic_wrk = Workflow.react_until_satisfied(state.runic_workflow, trigger_data)
      stop_reason = pending_stop_reason()

      if stop_reason do
        new_state = %{state | runic_workflow: new_runic_wrk}
        {:noreply, new_state}
      else
        # Sync the Runic graph results back to the Fizz context
        new_state = %{state | runic_workflow: new_runic_wrk, status: :completed}
        finalize_execution(new_state)

        # Flush step events to DB
        flush_step_executions(state.execution_id)

        # Emit completion event
        Events.emit(:execution_completed, new_state.execution_id, %{
          status: :completed
        })

        {:stop, :normal, new_state}
      end
    catch
      :throw, {:step_error, step_id, reason} ->
        state = handle_failure(state, step_id, reason)
        {:stop, :normal, state}

      kind, reason ->
        Logger.error("Execution failed unexpectedly: #{inspect(reason)}",
          kind: kind,
          stacktrace: __STACKTRACE__
        )

        state = handle_failure(state, "system", reason)
        {:stop, :normal, state}
    end
  end

  defp load_with_source(id) do
    execution =
      Execution
      |> Repo.get(id)
      |> Repo.preload(workflow: [:user, :draft, :published_version])

    if execution, do: {:ok, execution}, else: {:error, :not_found}
  end

  defp build_runic_workflow(execution, runtime_opts) do
    # Hydrate Runic Workflow from source
    runic_wrk = build_from_source(execution, runtime_opts)

    if runic_wrk do
      # Attach observability hooks for logging, telemetry, events
      hooked_wrk =
        Observability.attach_all_hooks(runic_wrk,
          execution_id: execution.id,
          workflow_id: execution.workflow_id
        )

      {:ok, hooked_wrk}
    else
      {:error, :missing_source}
    end
  end

  defp build_from_source(execution, runtime_opts) do
    source_override = Keyword.get(runtime_opts, :source) || Keyword.get(runtime_opts, :draft)

    case source_override || get_source(execution) do
      nil ->
        nil

      source ->
        # Merge runtime opts (like ephemeral PIDs) into metadata
        runtime_metadata =
          runtime_opts
          |> Keyword.drop([:source, :draft])
          |> Map.new()

        metadata =
          %{
            trace_id:
              (execution.metadata && Map.get(execution.metadata, :trace_id)) ||
                Map.get(execution.metadata || %{}, "trace_id"),
            workflow_id: execution.workflow_id
          }
          |> Map.merge(runtime_metadata)

        # Pass execution context to the adapter
        opts = [
          execution_id: execution.id,
          variables:
            (execution.metadata && Map.get(execution.metadata, :variables)) ||
              Map.get(execution.metadata || %{}, "variables", %{}),
          trigger_data: (execution.trigger && execution.trigger.data) || %{},
          trigger_type: (execution.trigger && execution.trigger.type) || :manual,
          metadata: metadata,
          step_outputs: Keyword.get(runtime_opts, :step_outputs, %{}),
          scope: Fizz.Accounts.Scope.for_user(execution.workflow.user)
        ]

        RunicAdapter.to_runic_workflow(source, opts)
    end
  end

  defp get_source(%Execution{
         execution_type: :production,
         workflow: %{published_version: version}
       })
       when not is_nil(version),
       do: version

  defp get_source(%Execution{workflow: %{draft: draft}}), do: draft
  defp get_source(_), do: nil

  defp handle_init_failure(execution_id, reason) do
    error_map = Execution.format_error(reason)

    Execution
    |> Repo.get!(execution_id)
    |> Execution.changeset(%{
      status: :failed,
      error: error_map,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()

    Events.emit(:execution_failed, execution_id, %{status: :failed, error: error_map})
  end

  defp update_status(id, status) do
    Task.start(fn ->
      now = DateTime.utc_now()

      Repo.update_all(
        from(e in Execution, where: e.id == ^id),
        set: [status: status, started_at: now, updated_at: now]
      )
    end)
  end

  defp finalize_execution(state) do
    context = Process.get(:fizz_accumulated_outputs, %{})

    Task.start(fn ->
      now = DateTime.utc_now()

      Repo.update_all(
        from(e in Execution, where: e.id == ^state.execution_id),
        set: [
          status: :completed,
          context: context,
          completed_at: now,
          updated_at: now
        ]
      )
    end)

    Logger.info("Execution completed successfully")
  end

  defp handle_failure(state, step_id, reason) do
    error_map = Execution.format_error({:step_failed, step_id, reason})
    completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Observability.push_step_event(%{
      execution_id: state.execution_id,
      step_id: step_id,
      status: :failed,
      error: error_map,
      completed_at: completed_at
    })

    step_execution =
      case Executions.record_step_execution_failed_by_step(state.execution_id, step_id, reason) do
        {:ok, step_execution} ->
          step_execution

        {:error, failure_reason} ->
          Logger.warning("Failed to persist step execution failure",
            execution_id: state.execution_id,
            step_id: step_id,
            reason: inspect(failure_reason)
          )

          nil
      end

    # Cancel any other steps that might be running/pending
    Executions.cancel_active_step_executions(state.execution_id)

    payload =
      %{
        execution_id: state.execution_id,
        step_id: step_id,
        status: :failed,
        error: error_map,
        completed_at: (step_execution && step_execution.completed_at) || completed_at
      }
      |> maybe_put_step_type(step_execution)

    Fizz.Executions.PubSub.broadcast_step(:step_failed, state.execution_id, nil, payload)

    Execution
    |> Repo.get!(state.execution_id)
    |> Execution.changeset(%{
      status: :failed,
      error: error_map,
      completed_at: completed_at
    })
    |> Repo.update!()

    # Emit execution failed event
    Events.emit(:execution_failed, state.execution_id, %{
      status: :failed,
      error: error_map
    })

    # Flush step events to DB
    flush_step_executions(state.execution_id)

    Logger.error("Execution failed at step #{step_id}: #{inspect(reason)}")

    state
  end

  defp maybe_put_step_type(payload, %{step_type_id: step_type_id})
       when not is_nil(step_type_id) do
    Map.put(payload, :step_type_id, step_type_id)
  end

  defp maybe_put_step_type(payload, step_execution) when is_map(step_execution) do
    case step_execution do
      %{step_type_id: step_type_id} when not is_nil(step_type_id) ->
        Map.put(payload, :step_type_id, step_type_id)

      _ ->
        payload
    end
  end

  defp maybe_put_step_type(payload, _step_execution), do: payload

  defp flush_step_executions(execution_id) do
    events = Observability.flush_step_events()

    if events != [] do
      # If the execution was cancelled, mark any active steps as cancelled
      execution = Repo.get(Execution, execution_id)

      events =
        if execution && execution.status == :cancelled do
          Enum.map(events, fn e ->
            cond do
              e.status == :running ->
                Map.put(e, :status, :cancelled)

              cancel_completed_after?(e, execution.completed_at) ->
                Map.put(e, :status, :cancelled)

              true ->
                e
            end
          end)
        else
          events
        end

      case Executions.record_step_executions_batch(events) do
        {:ok, _count} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to flush step executions batch", reason: inspect(reason))
      end
    end
  end

  defp pending_stop_reason do
    case Process.info(self(), :messages) do
      {:messages, messages} ->
        Enum.find_value(messages, fn
          {:system, _from, {:terminate, reason}} -> reason
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp cancel_completed_after?(_event, nil), do: false

  defp cancel_completed_after?(event, %DateTime{} = cancelled_at) do
    completed_at =
      case Map.get(event, :completed_at) || Map.get(event, "completed_at") do
        %DateTime{} = dt -> dt
        _ -> nil
      end

    case completed_at do
      %DateTime{} = dt -> DateTime.compare(dt, cancelled_at) in [:gt, :eq]
      _ -> false
    end
  end
end
