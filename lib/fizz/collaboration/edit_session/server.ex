defmodule Fizz.Collaboration.EditSession.Server do
  @moduledoc """
  GenServer managing a single collaborative editing session for a workflow.

  Responsibilities:
  - Maintain canonical workflow draft state
  - Process and linearize operations from all clients
  - Broadcast changes to all participants
  - Manage editor state (pins, disabled steps, locks)
  - Persist operations and snapshots
  """
  use GenServer, restart: :transient

  require Logger

  alias Fizz.Collaboration.{EditorState, EditOperation}
  alias Fizz.Collaboration.EditSession.{Inversion, Operations, Persistence, Presence, PubSub}
  alias Fizz.Collaboration.EditSession.{UndoEntry, UndoStack}
  alias Fizz.Workflows
  alias Ecto.UUID

  @idle_timeout :timer.minutes(30)
  @persist_interval :timer.seconds(5)
  @max_op_buffer 1000
  @webhook_test_timeout :timer.minutes(10)

  defmodule State do
    @moduledoc false
    defstruct [
      :scope,
      :workflow_id,
      :draft,
      :editor_state,
      :seq,
      :op_buffer,
      :applied_ops,
      :undo_stacks,
      :dirty,
      :persist_timer,
      :idle_timer,
      :webhook_test_timer
    ]
  end

  # =============================================================================
  # Client API
  # =============================================================================

  def start_link(opts) do
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    scope = Keyword.fetch!(opts, :scope)

    GenServer.start_link(__MODULE__, %{workflow_id: workflow_id, scope: scope},
      name: via_tuple(workflow_id)
    )
  end

  def via_tuple(workflow_id) do
    {:via, Registry, {Fizz.Collaboration.EditSession.Registry, workflow_id}}
  end

  @doc "Apply an operation to the workflow."
  def apply_operation(workflow_id, operation) do
    GenServer.call(via_tuple(workflow_id), {:apply_operation, operation})
  end

  @doc "Undo the last operation group for a user."
  def undo(workflow_id, user_id, count \\ 1) do
    GenServer.call(via_tuple(workflow_id), {:undo, user_id, count})
  end

  @doc "Redo the last undone operation group for a user."
  def redo(workflow_id, user_id, count \\ 1) do
    GenServer.call(via_tuple(workflow_id), {:redo, user_id, count})
  end

  @doc "Get undo/redo state for UI."
  def get_undo_state(workflow_id, user_id) do
    GenServer.call(via_tuple(workflow_id), {:get_undo_state, user_id})
  end

  @doc "Preview draft state after undoing N entries (no mutation)."
  def preview_undo(workflow_id, user_id, count \\ 1) do
    GenServer.call(via_tuple(workflow_id), {:preview_undo, user_id, count})
  end

  @doc "Get current state for a joining/reconnecting client."
  def get_sync_state(workflow_id, client_seq \\ nil) do
    GenServer.call(via_tuple(workflow_id), {:get_sync_state, client_seq})
  end

  @doc "Acquire a soft lock on a step for editing."
  def acquire_step_lock(workflow_id, step_id, user_id) do
    GenServer.call(via_tuple(workflow_id), {:acquire_lock, step_id, user_id})
  end

  @doc "Release a step lock."
  def release_step_lock(workflow_id, step_id, user_id) do
    GenServer.cast(via_tuple(workflow_id), {:release_lock, step_id, user_id})
  end

  @doc "Get current editor state (pins, disabled, locks)."
  def get_editor_state(workflow_id) do
    GenServer.call(via_tuple(workflow_id), :get_editor_state)
  end

  @doc "Force a persistence of current state."
  def persist(workflow_id) do
    GenServer.cast(via_tuple(workflow_id), :persist)
  end

  @doc "Force a persistence of current state and wait for completion."
  def persist_sync(workflow_id) do
    GenServer.call(via_tuple(workflow_id), :persist_sync)
  end

  @doc "Enable a temporary test webhook listener for a workflow."
  def enable_test_webhook(workflow_id, attrs) do
    with {:ok, pid} <- lookup_session_pid(workflow_id) do
      GenServer.call(pid, {:enable_test_webhook, attrs})
    end
  end

  @doc "Disable the active test webhook listener for a workflow."
  def disable_test_webhook(workflow_id, step_id \\ nil) do
    with {:ok, pid} <- lookup_session_pid(workflow_id) do
      GenServer.call(pid, {:disable_test_webhook, step_id})
    end
  end

  @doc "Check if a test webhook listener is active for a path and method."
  def test_webhook_enabled?(workflow_id, path, method) do
    with {:ok, pid} <- lookup_session_pid(workflow_id) do
      GenServer.call(pid, {:test_webhook_enabled?, path, method})
    else
      _ -> {:error, :not_listening}
    end
  end

  @doc "Broadcast that a test webhook execution was created for the session."
  def notify_webhook_test_execution(workflow_id, execution_id) do
    case lookup_session_pid(workflow_id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:webhook_test_execution, execution_id})
        :ok

      _ ->
        :ok
    end
  end

  # =============================================================================
  # Server Callbacks
  # =============================================================================

  @impl true
  def init(%{workflow_id: workflow_id, scope: scope}) do
    Logger.metadata(workflow_id: workflow_id, component: :edit_session)
    Logger.info("Starting edit session for workflow #{workflow_id}")

    case load_initial_state(workflow_id, scope) do
      {:ok, state} ->
        persist_timer = Process.send_after(self(), :persist, @persist_interval)
        idle_timer = Process.send_after(self(), :idle_timeout, @idle_timeout)

        state = %{
          state
          | persist_timer: persist_timer,
            idle_timer: idle_timer
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to load initial state: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:apply_operation, operation}, _from, state) do
    case process_operation(state, operation, track_undo: true) do
      {:ok, new_state, result} ->
        new_state = reset_idle_timer(new_state)
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:undo, user_id, count}, _from, state) do
    case apply_undo(state, user_id, count) do
      {:ok, new_state, result} ->
        new_state = reset_idle_timer(new_state)
        {:reply, {:ok, result}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:redo, user_id, count}, _from, state) do
    case apply_redo(state, user_id, count) do
      {:ok, new_state, result} ->
        new_state = reset_idle_timer(new_state)
        {:reply, {:ok, result}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:get_undo_state, user_id}, _from, state) do
    {:reply, {:ok, build_undo_state(state, user_id)}, state}
  end

  def handle_call({:preview_undo, user_id, count}, _from, state) do
    {:reply, preview_undo_state(state, user_id, count), state}
  end

  def handle_call({:get_sync_state, client_seq}, _from, state) do
    response = build_sync_response(state, client_seq)
    {:reply, {:ok, response}, state}
  end

  def handle_call({:acquire_lock, step_id, user_id}, _from, state) do
    case EditorState.acquire_lock(state.editor_state, step_id, user_id) do
      {:ok, new_editor_state} ->
        new_state = %{state | editor_state: new_editor_state}
        PubSub.broadcast_lock_acquired(state.workflow_id, step_id, user_id)
        {:reply, :ok, new_state}

      {:locked, other_user_id} ->
        {:reply, {:error, {:locked_by, other_user_id}}, state}
    end
  end

  def handle_call(:get_editor_state, _from, state) do
    {:reply, {:ok, state.editor_state}, state}
  end

  def handle_call({:enable_test_webhook, attrs}, _from, state) do
    case resolve_webhook_test(state.draft, attrs) do
      {:ok, webhook_test} ->
        editor_state = EditorState.enable_webhook_test(state.editor_state, webhook_test)

        state =
          state
          |> cancel_webhook_test_timer()
          |> schedule_webhook_test_timer(webhook_test)
          |> Map.put(:editor_state, editor_state)

        broadcast_editor_state_update(state.workflow_id, editor_state)
        {:reply, {:ok, webhook_test}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:disable_test_webhook, step_id}, _from, state) do
    {state, editor_state_changed} = maybe_disable_webhook_test(state, step_id)

    if editor_state_changed do
      broadcast_editor_state_update(state.workflow_id, state.editor_state)
    end

    {:reply, :ok, state}
  end

  def handle_call({:test_webhook_enabled?, path, method}, _from, state) do
    case webhook_test_matches?(state.editor_state.webhook_test, path, method) do
      {:ok, webhook_test} -> {:reply, {:ok, webhook_test}, state}
      :error -> {:reply, {:error, :not_listening}, state}
    end
  end

  def handle_call(:persist_sync, _from, state) do
    {result, new_state} = persist_state(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_cast({:release_lock, step_id, user_id}, state) do
    new_editor_state = EditorState.release_lock(state.editor_state, step_id, user_id)
    new_state = %{state | editor_state: new_editor_state}
    PubSub.broadcast_lock_released(state.workflow_id, step_id)
    {:noreply, new_state}
  end

  def handle_cast(:persist, state) do
    {_result, new_state} = persist_state(state)
    {:noreply, new_state}
  end

  def handle_cast({:webhook_test_execution, execution_id}, state) do
    PubSub.broadcast_webhook_test_execution(state.workflow_id, execution_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:persist, state) do
    {_result, new_state} = persist_state(state)
    persist_timer = Process.send_after(self(), :persist, @persist_interval)
    {:noreply, %{new_state | persist_timer: persist_timer}}
  end

  def handle_info({:webhook_test_timeout, key}, state) do
    {state, editor_state_changed} = maybe_disable_webhook_test(state, key)

    if editor_state_changed do
      broadcast_editor_state_update(state.workflow_id, state.editor_state)
    end

    {:noreply, state}
  end

  def handle_info(:idle_timeout, state) do
    if Presence.count(state.workflow_id) == 0 do
      Logger.info("Edit session idle with no users, shutting down")
      Persistence.persist(state)
      {:stop, :normal, state}
    else
      idle_timer = Process.send_after(self(), :idle_timeout, @idle_timeout)
      {:noreply, %{state | idle_timer: idle_timer}}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Edit session terminating", reason: inspect(reason))

    try do
      Persistence.persist(state)
    catch
      :exit, _ -> :ok
      :error, _ -> :ok
    end

    :ok
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp load_initial_state(workflow_id, scope) do
    with {:ok, draft} <- get_or_create_draft(scope, workflow_id),
         last_persisted_seq <- (draft.settings || %{})["last_persisted_seq"] || 0,
         {:ok, ops} <- Persistence.load_pending_ops(workflow_id, last_persisted_seq) do
      editor_state =
        EditorState.from_storage(
          workflow_id,
          Map.get(draft, :editor_state) || %{},
          draft.settings || %{}
        )

      {draft, editor_state, seq} =
        replay_operations(draft, editor_state, ops, last_persisted_seq)

      state = %State{
        scope: scope,
        workflow_id: workflow_id,
        draft: draft,
        editor_state: editor_state,
        seq: seq,
        op_buffer: ops,
        applied_ops: MapSet.new(Enum.map(ops, & &1.operation_id)),
        undo_stacks: %{},
        dirty: false
      }

      {:ok, state}
    end
  end

  defp get_or_create_draft(scope, workflow_id) do
    case Workflows.get_draft(scope, workflow_id) do
      {:ok, draft} ->
        {:ok, draft}

      {:error, :not_found} ->
        create_empty_draft(scope, workflow_id)
    end
  end

  defp create_empty_draft(scope, workflow_id) do
    with {:ok, workflow} <- Workflows.get_workflow(scope, workflow_id),
         {:ok, draft} <-
           Workflows.update_workflow_draft(scope, workflow, %{
             steps: [],
             connections: [],
             groups: [],
             settings: %{}
           }) do
      {:ok, draft}
    else
      {:error, :access_denied} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_operations(draft, editor_state, ops, initial_seq) do
    try do
      Enum.reduce(ops, {draft, editor_state, initial_seq}, fn op, {d, state, seq} ->
        {new_draft, new_editor_state, _editor_state_changed} = apply_to_state(d, state, op)
        {new_draft, new_editor_state, max(seq, op.seq)}
      end)
    rescue
      error ->
        Logger.error("Failed to replay operations during recovery: #{inspect(error)}")

        {draft, editor_state, initial_seq}
    end
  end

  defp process_operation(state, operation, opts) do
    track_undo = Keyword.get(opts, :track_undo, false)

    if MapSet.member?(state.applied_ops, operation.id) do
      existing_op = Enum.find(state.op_buffer, &(&1.operation_id == operation.id))
      {:ok, state, %{seq: existing_op.seq, status: :duplicate}}
    else
      with :ok <- Operations.validate(state.draft, operation),
           {:ok, inverse_ops} <- maybe_compute_inverse(state, operation, track_undo) do
        new_seq = state.seq + 1

        {new_draft, new_editor_state, editor_state_changed} =
          apply_to_state(state.draft, state.editor_state, operation)

        op_record = %EditOperation{
          operation_id: operation.id,
          seq: new_seq,
          type: operation.type,
          payload: operation.payload,
          user_id: operation.user_id,
          client_seq: Map.get(operation, :client_seq),
          workflow_id: state.workflow_id
        }

        new_state =
          state
          |> Map.put(:draft, new_draft)
          |> Map.put(:editor_state, new_editor_state)
          |> Map.put(:seq, new_seq)
          |> Map.put(:op_buffer, append_to_buffer(state.op_buffer, op_record))
          |> Map.put(:applied_ops, MapSet.put(state.applied_ops, operation.id))
          |> Map.put(:dirty, true)
          |> maybe_track_undo(operation, inverse_ops, track_undo)

        # Broadcast the operation to all subscribers
        Logger.debug(
          "Broadcasting operation #{op_record.operation_id} (type: #{op_record.type}) to topic #{PubSub.session_topic(state.workflow_id)}"
        )

        PubSub.broadcast_operation(state.workflow_id, op_record)

        # If editor state changed, broadcast that too
        if editor_state_changed do
          Logger.debug("Broadcasting editor_state_updated for workflow #{state.workflow_id}")
          broadcast_editor_state_update(state.workflow_id, new_editor_state)
        end

        {:ok, new_state, %{seq: new_seq, status: :applied}}
      end
    end
  end

  defp maybe_compute_inverse(_state, _operation, false), do: {:ok, []}

  defp maybe_compute_inverse(state, operation, true) do
    case Inversion.compute_inverse(state.draft, state.editor_state, operation) do
      {:ok, inverse_ops} -> {:ok, inverse_ops}
      {:error, reason} -> {:error, {:undo_inverse_failed, reason}}
    end
  end

  defp maybe_track_undo(state, _operation, _inverse_ops, false), do: state

  defp maybe_track_undo(state, operation, inverse_ops, true) do
    user_id = operation.user_id
    group_id = Map.get(operation, :undo_group_id)

    label =
      Map.get(operation, :undo_label) ||
        infer_undo_label(state.draft, state.editor_state, operation)

    entry = build_undo_entry(operation, inverse_ops, label, group_id)
    update_user_undo_stack(state, user_id, entry, group_id)
  end

  defp build_undo_entry(operation, inverse_ops, label, group_id) do
    %UndoEntry{
      id: UUID.generate(),
      group_id: group_id,
      label: label,
      timestamp: DateTime.utc_now(),
      user_id: operation.user_id,
      operations: [operation_for_entry(operation)],
      inverse_ops: inverse_ops
    }
  end

  defp update_user_undo_stack(state, user_id, entry, group_id) do
    stack = get_user_undo_stack(state, user_id)

    updated_stack =
      case {group_id, stack.undo} do
        {nil, _} ->
          UndoStack.push(stack, entry)

        {^group_id, [%UndoEntry{group_id: ^group_id} = head | rest]} ->
          merged = merge_undo_entry(head, entry)
          UndoStack.push(%{stack | undo: rest}, merged)

        _ ->
          UndoStack.push(stack, entry)
      end

    put_user_undo_stack(state, user_id, updated_stack)
  end

  defp merge_undo_entry(existing, incoming) do
    %UndoEntry{
      existing
      | label: existing.label || incoming.label,
        timestamp: incoming.timestamp,
        operations: existing.operations ++ incoming.operations,
        inverse_ops: incoming.inverse_ops ++ existing.inverse_ops
    }
  end

  defp operation_for_entry(operation) do
    %{type: operation.type, payload: operation.payload}
  end

  defp get_user_undo_stack(state, user_id) do
    Map.get(state.undo_stacks || %{}, user_id, UndoStack.new())
  end

  defp put_user_undo_stack(state, user_id, stack) do
    %{state | undo_stacks: Map.put(state.undo_stacks || %{}, user_id, stack)}
  end

  defp build_undo_state(state, user_id) do
    stack = get_user_undo_stack(state, user_id)
    next_undo = List.first(stack.undo)
    next_redo = List.first(stack.redo)
    undo_stack = build_undo_entries(stack.undo)
    redo_stack = build_undo_entries(stack.redo)

    %{
      canUndo: stack.undo != [],
      canRedo: stack.redo != [],
      undoLabel: if(next_undo, do: next_undo.label, else: nil),
      redoLabel: if(next_redo, do: next_redo.label, else: nil),
      undoStack: undo_stack,
      redoStack: redo_stack
    }
  end

  defp build_undo_entries(entries) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> format_undo_entry(entry, index + 1) end)
  end

  defp build_undo_entries(_entries), do: []

  defp format_undo_entry(%UndoEntry{} = entry, depth) do
    %{
      id: entry.id,
      label: entry.label,
      timestamp: format_timestamp(entry.timestamp),
      depth: depth
    }
  end

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(_timestamp), do: nil

  defp preview_undo_state(state, user_id, count) do
    count =
      case count do
        value when is_integer(value) and value > 0 ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {parsed, _} when parsed > 0 -> parsed
            _ -> 1
          end

        _ ->
          1
      end

    stack = get_user_undo_stack(state, user_id)
    entries = Enum.take(stack.undo, count)
    operations = Enum.flat_map(entries, fn entry -> entry.inverse_ops || [] end)

    case simulate_operations(state, operations) do
      {:ok, draft, _editor_state} -> {:ok, draft}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_undo(state, user_id, count) when count > 0 do
    Enum.reduce_while(1..count, {:ok, state, %{label: nil, operation_count: 0}}, fn _,
                                                                                    {:ok,
                                                                                     acc_state,
                                                                                     acc_result} ->
      case apply_single_undo(acc_state, user_id) do
        {:ok, new_state, result} ->
          updated_result = %{
            label: result.label,
            operation_count: acc_result.operation_count + result.operation_count
          }

          {:cont, {:ok, new_state, updated_result}}

        {:error, reason, new_state} ->
          {:halt, {:error, reason, new_state}}
      end
    end)
  end

  defp apply_undo(state, _user_id, _count), do: {:error, :invalid_undo_count, state}

  defp apply_redo(state, user_id, count) when count > 0 do
    Enum.reduce_while(1..count, {:ok, state, %{label: nil, operation_count: 0}}, fn _,
                                                                                    {:ok,
                                                                                     acc_state,
                                                                                     acc_result} ->
      case apply_single_redo(acc_state, user_id) do
        {:ok, new_state, result} ->
          updated_result = %{
            label: result.label,
            operation_count: acc_result.operation_count + result.operation_count
          }

          {:cont, {:ok, new_state, updated_result}}

        {:error, reason, new_state} ->
          {:halt, {:error, reason, new_state}}
      end
    end)
  end

  defp apply_redo(state, _user_id, _count), do: {:error, :invalid_redo_count, state}

  defp apply_single_undo(state, user_id) do
    case UndoStack.pop_undo(get_user_undo_stack(state, user_id)) do
      :empty ->
        {:error, :nothing_to_undo, state}

      {:ok, entry, stack_after_pop} ->
        case simulate_operations(state, entry.inverse_ops) do
          {:ok, _draft, _editor_state} ->
            case apply_operations_without_tracking(state, user_id, entry.inverse_ops) do
              {:ok, new_state} ->
                updated_stack = %{stack_after_pop | redo: [entry | stack_after_pop.redo]}
                new_state = put_user_undo_stack(new_state, user_id, updated_stack)
                result = %{label: entry.label, operation_count: length(entry.inverse_ops)}
                {:ok, new_state, result}

              {:error, reason, new_state} ->
                {:error, {:conflict, reason, entry.label}, new_state}
            end

          {:error, reason} ->
            new_state = put_user_undo_stack(state, user_id, stack_after_pop)
            {:error, {:conflict, reason, entry.label}, new_state}
        end
    end
  end

  defp apply_single_redo(state, user_id) do
    case UndoStack.pop_redo(get_user_undo_stack(state, user_id)) do
      :empty ->
        {:error, :nothing_to_redo, state}

      {:ok, entry, stack_after_pop} ->
        case simulate_operations(state, entry.operations) do
          {:ok, _draft, _editor_state} ->
            case apply_operations_without_tracking(state, user_id, entry.operations) do
              {:ok, new_state} ->
                updated_stack = %{stack_after_pop | undo: [entry | stack_after_pop.undo]}
                new_state = put_user_undo_stack(new_state, user_id, updated_stack)
                result = %{label: entry.label, operation_count: length(entry.operations)}
                {:ok, new_state, result}

              {:error, reason, new_state} ->
                {:error, {:conflict, reason, entry.label}, new_state}
            end

          {:error, reason} ->
            new_state = put_user_undo_stack(state, user_id, stack_after_pop)
            {:error, {:conflict, reason, entry.label}, new_state}
        end
    end
  end

  defp simulate_operations(state, operations) do
    Enum.reduce_while(operations, {:ok, state.draft, state.editor_state}, fn op,
                                                                             {:ok, draft,
                                                                              editor_state} ->
      case Operations.validate(draft, op) do
        :ok ->
          {new_draft, new_editor_state, _changed} = apply_to_state(draft, editor_state, op)
          {:cont, {:ok, new_draft, new_editor_state}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_operations_without_tracking(state, user_id, operations) do
    Enum.reduce_while(operations, {:ok, state}, fn op, {:ok, acc_state} ->
      operation = %{
        id: UUID.generate(),
        type: op.type,
        payload: op.payload,
        user_id: user_id,
        client_seq: nil
      }

      case process_operation(acc_state, operation, track_undo: false) do
        {:ok, new_state, _result} -> {:cont, {:ok, new_state}}
        {:error, reason} -> {:halt, {:error, reason, acc_state}}
      end
    end)
  end

  defp infer_undo_label(draft, _editor_state, operation) do
    type = operation.type
    payload = operation.payload || %{}

    case type do
      :add_step ->
        step = Map.get(payload, :step) || Map.get(payload, "step") || %{}
        "Add Step: #{Map.get(step, :name) || Map.get(step, "name") || "Step"}"

      :remove_step ->
        step_id = Map.get(payload, :step_id) || Map.get(payload, "step_id")
        "Delete Step: #{lookup_step_name(draft, step_id)}"

      :update_step_config ->
        step_id = Map.get(payload, :step_id) || Map.get(payload, "step_id")
        "Edit Config: #{lookup_step_name(draft, step_id)}"

      :update_step_position ->
        step_id = Map.get(payload, :step_id) || Map.get(payload, "step_id")
        "Move Step: #{lookup_step_name(draft, step_id)}"

      :update_step_positions ->
        step_positions =
          Map.get(payload, :step_positions) || Map.get(payload, "step_positions") || %{}

        count = map_size(step_positions)
        "Move #{count} Step#{if(count == 1, do: "", else: "s")}"

      :update_step_metadata ->
        step_id = Map.get(payload, :step_id) || Map.get(payload, "step_id")
        "Update Step: #{lookup_step_name(draft, step_id)}"

      :add_connection ->
        "Add Connection"

      :remove_connection ->
        "Remove Connection"

      :add_group ->
        group = Map.get(payload, :group) || Map.get(payload, "group") || %{}
        "Add Group: #{Map.get(group, :name) || Map.get(group, "name") || "Group"}"

      :update_group ->
        group_id = Map.get(payload, :group_id) || Map.get(payload, "group_id")
        "Update Group: #{lookup_group_name(draft, group_id)}"

      :remove_group ->
        group_id = Map.get(payload, :group_id) || Map.get(payload, "group_id")
        "Remove Group: #{lookup_group_name(draft, group_id)}"

      :set_group_membership ->
        "Update Group Members"

      :pin_step_output ->
        step_id = Map.get(payload, :step_id) || Map.get(payload, "step_id")
        "Pin Output: #{lookup_step_name(draft, step_id)}"

      :unpin_step_output ->
        step_id = Map.get(payload, :step_id) || Map.get(payload, "step_id")
        "Unpin Output: #{lookup_step_name(draft, step_id)}"

      :disable_step ->
        step_id = Map.get(payload, :step_id) || Map.get(payload, "step_id")
        "Disable Step: #{lookup_step_name(draft, step_id)}"

      :enable_step ->
        step_id = Map.get(payload, :step_id) || Map.get(payload, "step_id")
        "Enable Step: #{lookup_step_name(draft, step_id)}"

      _ ->
        "Undo"
    end
  end

  defp lookup_step_name(draft, step_id) do
    draft.steps
    |> List.wrap()
    |> Enum.find_value("Step", fn step ->
      if Map.get(step, :id) == step_id or Map.get(step, "id") == step_id do
        Map.get(step, :name) || Map.get(step, "name")
      end
    end)
  end

  defp lookup_group_name(draft, group_id) do
    draft.groups
    |> List.wrap()
    |> Enum.find_value("Group", fn group ->
      if Map.get(group, :id) == group_id or Map.get(group, "id") == group_id do
        Map.get(group, :name) || Map.get(group, "name")
      end
    end)
  end

  defp apply_to_state(draft, editor_state, operation) do
    case operation.type do
      # Workflow structure operations - modify draft
      type
      when type in [
             :add_step,
             :remove_step,
             :update_step_config,
             :update_step_position,
             :update_step_positions,
             :update_step_metadata,
             :add_connection,
             :remove_connection,
             :add_group,
             :update_group,
             :remove_group,
             :set_group_membership
           ] ->
        case Operations.apply(draft, operation) do
          {:ok, new_draft} ->
            # Clean up editor state if step was removed
            new_editor_state =
              if type == :remove_step do
                step_id =
                  Map.get(operation.payload, :step_id) || Map.get(operation.payload, "step_id")

                editor_state
                |> EditorState.unpin_output(step_id)
                |> EditorState.enable_step(step_id)
              else
                editor_state
              end

            {new_draft, new_editor_state, type == :remove_step}

          {:error, reason} ->
            Logger.error(
              "Failed to apply operation #{inspect(operation.type)}: #{inspect(reason)}"
            )

            {draft, editor_state, false}
        end

      # Editor-only operations - modify editor state only
      :pin_step_output ->
        step_id = Map.get(operation.payload, :step_id) || Map.get(operation.payload, "step_id")

        output_data =
          cond do
            Map.has_key?(operation.payload, :output_data) ->
              Map.get(operation.payload, :output_data)

            Map.has_key?(operation.payload, "output_data") ->
              Map.get(operation.payload, "output_data")

            true ->
              %{}
          end

        new_editor_state =
          EditorState.pin_output(
            editor_state,
            step_id,
            output_data
          )

        {draft, new_editor_state, true}

      :unpin_step_output ->
        step_id = Map.get(operation.payload, :step_id) || Map.get(operation.payload, "step_id")

        new_editor_state =
          EditorState.unpin_output(
            editor_state,
            step_id
          )

        {draft, new_editor_state, true}

      :disable_step ->
        step_id = Map.get(operation.payload, :step_id) || Map.get(operation.payload, "step_id")
        mode = Map.get(operation.payload, :mode) || Map.get(operation.payload, "mode") || :skip

        new_editor_state =
          EditorState.disable_step(
            editor_state,
            step_id,
            mode
          )

        {draft, new_editor_state, true}

      :enable_step ->
        new_editor_state =
          EditorState.enable_step(
            editor_state,
            Map.get(operation.payload, :step_id) || Map.get(operation.payload, "step_id")
          )

        {draft, new_editor_state, true}

      _ ->
        {draft, editor_state, false}
    end
  end

  defp lookup_session_pid(workflow_id) do
    case Registry.lookup(Fizz.Collaboration.EditSession.Registry, workflow_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp resolve_webhook_test(draft, attrs) do
    step_id = Map.get(attrs, :step_id) || Map.get(attrs, "step_id")
    path = Map.get(attrs, :path) || Map.get(attrs, "path")
    method = Map.get(attrs, :method) || Map.get(attrs, "method")
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id")

    case find_webhook_step(draft, step_id, path) do
      {:ok, step, path_from_step} ->
        method =
          normalize_method(
            Map.get(step.config, "http_method") || Map.get(step.config, :http_method) || method
          )

        {:ok,
         %{
           step_id: step.id,
           path: path_from_step,
           method: method,
           enabled_by: user_id
         }}

      :error ->
        normalized_path = normalize_path(path)
        normalized_method = normalize_method(method)

        if webhook_trigger_exists?(draft, normalized_path, normalized_method) do
          {:ok,
           %{
             step_id: step_id,
             path: normalized_path,
             method: normalized_method,
             enabled_by: user_id
           }}
        else
          {:error, :webhook_not_found}
        end
    end
  end

  defp find_webhook_step(_draft, nil, nil), do: :error

  defp find_webhook_step(draft, step_id, path) do
    step =
      Enum.find(draft.steps, fn step ->
        step.id == step_id && step.type_id == "webhook_trigger"
      end)

    cond do
      step ->
        {:ok, step,
         normalize_path(Map.get(step.config, "path") || Map.get(step.config, :path) || step.id)}

      true ->
        normalized_path = normalize_path(path)

        step_by_path =
          Enum.find(draft.steps, fn step ->
            step.type_id == "webhook_trigger" &&
              normalize_path(
                Map.get(step.config, "path") || Map.get(step.config, :path) || step.id
              ) ==
                normalized_path
          end)

        if step_by_path do
          {:ok, step_by_path,
           normalize_path(
             Map.get(step_by_path.config, "path") || Map.get(step_by_path.config, :path) ||
               step_by_path.id
           )}
        else
          :error
        end
    end
  end

  defp webhook_trigger_exists?(_draft, nil, _method), do: false

  defp webhook_trigger_exists?(draft, path, method) do
    # Only search steps (triggers are now steps)
    Enum.any?(draft.steps || [], fn step ->
      step.type_id == "webhook_trigger" &&
        normalize_path(Map.get(step.config, "path") || Map.get(step.config, :path) || step.id) ==
          path &&
        method_matches?(
          Map.get(step.config, "http_method") || Map.get(step.config, :http_method),
          method
        )
    end)
  end

  defp webhook_test_matches?(nil, _path, _method), do: :error

  defp webhook_test_matches?(webhook_test, path, method) do
    normalized_path = normalize_path(path)
    normalized_method = normalize_method(method)

    if webhook_test.path == normalized_path &&
         method_matches?(webhook_test.method, normalized_method) do
      {:ok, webhook_test}
    else
      :error
    end
  end

  defp normalize_path(nil), do: nil

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_method(nil), do: "POST"

  defp normalize_method(method) when is_binary(method) do
    method
    |> String.trim()
    |> case do
      "" -> "POST"
      trimmed -> String.upcase(trimmed)
    end
  end

  defp method_matches?(configured_method, incoming_method) do
    normalized_config = normalize_method(configured_method)
    normalized_incoming = normalize_method(incoming_method)

    normalized_config == "ANY" or normalized_config == normalized_incoming
  end

  defp schedule_webhook_test_timer(state, webhook_test) do
    key = webhook_test_key(webhook_test)
    timer = Process.send_after(self(), {:webhook_test_timeout, key}, @webhook_test_timeout)
    %{state | webhook_test_timer: timer}
  end

  defp cancel_webhook_test_timer(state) do
    if state.webhook_test_timer do
      Process.cancel_timer(state.webhook_test_timer)
    end

    %{state | webhook_test_timer: nil}
  end

  defp webhook_test_key(%{step_id: step_id}) when is_binary(step_id), do: {:step, step_id}
  defp webhook_test_key(%{path: path}) when is_binary(path), do: {:path, path}
  defp webhook_test_key(_), do: :unknown

  defp maybe_disable_webhook_test(state, nil) do
    do_disable_webhook_test(state, state.editor_state.webhook_test)
  end

  defp maybe_disable_webhook_test(state, {:step, step_id}) do
    current = state.editor_state.webhook_test

    if current && current.step_id == step_id do
      do_disable_webhook_test(state, current)
    else
      {state, false}
    end
  end

  defp maybe_disable_webhook_test(state, {:path, path}) do
    current = state.editor_state.webhook_test

    if current && current.path == path do
      do_disable_webhook_test(state, current)
    else
      {state, false}
    end
  end

  defp maybe_disable_webhook_test(state, step_id) when is_binary(step_id) do
    current = state.editor_state.webhook_test

    if current && current.step_id == step_id do
      do_disable_webhook_test(state, current)
    else
      {state, false}
    end
  end

  defp maybe_disable_webhook_test(state, _step_id), do: {state, false}

  defp do_disable_webhook_test(state, nil), do: {cancel_webhook_test_timer(state), false}

  defp do_disable_webhook_test(state, _current) do
    editor_state = EditorState.disable_webhook_test(state.editor_state)

    state =
      state
      |> cancel_webhook_test_timer()
      |> Map.put(:editor_state, editor_state)

    {state, true}
  end

  defp broadcast_editor_state_update(workflow_id, editor_state) do
    PubSub.broadcast_editor_state_updated(workflow_id, editor_state)
  end

  defp append_to_buffer(buffer, op) do
    [op | buffer]
    |> Enum.take(@max_op_buffer)
  end

  defp build_sync_response(state, nil) do
    %{
      type: :full_sync,
      draft: state.draft,
      editor_state: serialize_editor_state(state.editor_state),
      seq: state.seq
    }
  end

  defp build_sync_response(state, client_seq) do
    gap = state.seq - client_seq

    cond do
      gap == 0 ->
        %{type: :up_to_date, seq: state.seq}

      gap > 0 and gap <= length(state.op_buffer) ->
        ops =
          state.op_buffer
          |> Enum.filter(&(&1.seq > client_seq))
          |> Enum.sort_by(& &1.seq)

        %{type: :incremental, ops: ops, seq: state.seq}

      true ->
        %{
          type: :full_sync,
          draft: state.draft,
          editor_state: serialize_editor_state(state.editor_state),
          seq: state.seq
        }
    end
  end

  defp serialize_editor_state(editor_state) do
    %{
      pinned_outputs: editor_state.pinned_outputs,
      disabled_steps: MapSet.to_list(editor_state.disabled_steps),
      step_locks: editor_state.step_locks,
      webhook_test: editor_state.webhook_test
    }
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    idle_timer = Process.send_after(self(), :idle_timeout, @idle_timeout)
    %{state | idle_timer: idle_timer}
  end

  defp persist_state(state) do
    if state.dirty do
      case Persistence.persist(state) do
        :ok ->
          Logger.debug("Persisted edit session state")
          {:ok, %{state | dirty: false}}

        {:error, reason} ->
          Logger.error("Failed to persist: #{inspect(reason)}")
          {{:error, reason}, state}
      end
    else
      {:noop, state}
    end
  end
end
