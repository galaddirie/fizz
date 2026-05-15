defmodule Fizz.Workflows.DraftSession do
  @moduledoc false

  use GenServer

  alias Fizz.Workflows
  alias Fizz.Workflows.DraftSession.Operation
  alias Fizz.Workflows.SlotDefaults
  alias Fizz.Workflows.WorkflowDefinitionVersion

  require Logger

  @default_persist_debounce_ms 1_000
  @default_persist_retry_base_ms 1_000
  @default_persist_retry_max_ms 30_000
  @default_idle_timeout_ms :timer.minutes(5)

  defstruct [
    :version_id,
    :draft,
    :seq,
    :undo_stacks,
    :redo_stacks,
    :dirty?,
    :connected_users,
    :persist_timer_ref,
    :persist_retry_attempt,
    :idle_timer_ref,
    :scope,
    :save_status,
    :save_error,
    :editor_state
  ]

  @type save_status :: :saved | :saving | :error
  @type persistence_state :: %{status: save_status(), error: term() | nil}

  @type t :: %__MODULE__{
          version_id: String.t(),
          draft: WorkflowDefinitionVersion.t(),
          seq: non_neg_integer(),
          undo_stacks: %{optional(String.t()) => [map()]},
          redo_stacks: %{optional(String.t()) => [map()]},
          dirty?: boolean(),
          connected_users: MapSet.t(String.t()),
          persist_timer_ref: reference() | nil,
          persist_retry_attempt: non_neg_integer(),
          idle_timer_ref: reference() | nil,
          scope: term(),
          save_status: save_status(),
          save_error: term() | nil,
          editor_state: map()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    version_id = Keyword.fetch!(opts, :version_id)

    %{
      id: {__MODULE__, version_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    version_id = Keyword.fetch!(opts, :version_id)
    registry = Keyword.get(opts, :registry, Fizz.Workflows.DraftSessionRegistry)

    GenServer.start_link(__MODULE__, opts, name: via_tuple(registry, version_id))
  end

  @spec join(String.t(), term(), String.t()) ::
          {:ok, WorkflowDefinitionVersion.t(), non_neg_integer(), map(), map()} | {:error, term()}
  def join(version_id, scope, user_id) when is_binary(version_id) and is_binary(user_id) do
    with {:ok, pid} <- ensure_started(version_id, scope) do
      GenServer.call(pid, {:join, scope, user_id}, :infinity)
    end
  end

  @spec leave(String.t(), String.t()) :: :ok | {:error, :not_found}
  def leave(version_id, user_id) when is_binary(version_id) and is_binary(user_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:leave, user_id}, :infinity)
    end
  end

  @spec apply_operation(String.t(), String.t(), map()) ::
          {:ok, WorkflowDefinitionVersion.t(), non_neg_integer(), map()} | {:error, term()}
  def apply_operation(version_id, user_id, operation)
      when is_binary(version_id) and is_binary(user_id) and is_map(operation) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:apply_operation, user_id, operation}, :infinity)
    end
  end

  @spec undo(String.t(), String.t()) ::
          {:ok, WorkflowDefinitionVersion.t(), non_neg_integer(), map()} | {:error, term()}
  def undo(version_id, user_id) when is_binary(version_id) and is_binary(user_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:undo, user_id}, :infinity)
    end
  end

  @spec redo(String.t(), String.t()) ::
          {:ok, WorkflowDefinitionVersion.t(), non_neg_integer(), map()} | {:error, term()}
  def redo(version_id, user_id) when is_binary(version_id) and is_binary(user_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:redo, user_id}, :infinity)
    end
  end

  @spec persist_now(String.t()) ::
          {:ok, WorkflowDefinitionVersion.t(), non_neg_integer()} | {:error, term()}
  def persist_now(version_id) when is_binary(version_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, :persist_now, :infinity)
    end
  end

  @spec get_undo_state(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_undo_state(version_id, user_id) when is_binary(version_id) and is_binary(user_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:get_undo_state, user_id}, :infinity)
    end
  end

  @spec get_persistence_state(String.t()) :: {:ok, persistence_state()} | {:error, term()}
  def get_persistence_state(version_id) when is_binary(version_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, :get_persistence_state, :infinity)
    end
  end

  @spec get_editor_state(String.t()) :: {:ok, map()} | {:error, term()}
  def get_editor_state(version_id) when is_binary(version_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, :get_editor_state, :infinity)
    end
  end

  @spec preview_revision(
          String.t(),
          String.t(),
          :current | {:undo, pos_integer()} | {:version, String.t()}
        ) ::
          {:ok, WorkflowDefinitionVersion.t()} | {:error, term()}
  def preview_revision(version_id, user_id, revision)
      when is_binary(version_id) and is_binary(user_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:preview_revision, user_id, revision}, :infinity)
    end
  end

  @spec pin_output(String.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def pin_output(version_id, step_id, output_data)
      when is_binary(version_id) and is_binary(step_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:pin_output, step_id, output_data}, :infinity)
    end
  end

  @spec unpin_output(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def unpin_output(version_id, step_id) when is_binary(version_id) and is_binary(step_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:unpin_output, step_id}, :infinity)
    end
  end

  @spec disable_step(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def disable_step(version_id, step_id) when is_binary(version_id) and is_binary(step_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:disable_step, step_id}, :infinity)
    end
  end

  @spec enable_step(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def enable_step(version_id, step_id) when is_binary(version_id) and is_binary(step_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:enable_step, step_id}, :infinity)
    end
  end

  @spec snapshot(String.t(), String.t()) ::
          {:ok,
           %{
             draft: WorkflowDefinitionVersion.t(),
             seq: non_neg_integer(),
             undo_state: map(),
             persistence: persistence_state(),
             editor_state: map()
           }}
          | {:error, term()}
  def snapshot(version_id, user_id) when is_binary(version_id) and is_binary(user_id) do
    with {:ok, pid} <- lookup_pid(version_id) do
      GenServer.call(pid, {:snapshot, user_id}, :infinity)
    end
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    version_id = Keyword.fetch!(opts, :version_id)
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, draft} <- Workflows.get_version(scope, version_id),
         :ok <- ensure_draft(draft) do
      {:ok,
       %__MODULE__{
         version_id: version_id,
         draft: draft,
         seq: 0,
         undo_stacks: %{},
         redo_stacks: %{},
         dirty?: false,
         connected_users: MapSet.new(),
         persist_timer_ref: nil,
         persist_retry_attempt: 0,
         idle_timer_ref: nil,
         scope: scope,
         save_status: :saved,
         save_error: nil,
         editor_state: %{pinned_outputs: %{}, disabled_steps: [], step_locks: %{}}
       }}
    else
      {:error, _reason} = error -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:join, scope, user_id}, _from, state) do
    next_state =
      state
      |> cancel_idle_timeout()
      |> Map.put(:scope, scope)
      |> put_connected_user(user_id)

    {:reply,
     {:ok, next_state.draft, next_state.seq, undo_state(next_state, user_id),
      next_state.editor_state}, next_state}
  end

  def handle_call({:leave, user_id}, _from, state) do
    state = remove_connected_user(state, user_id)

    next_state =
      case MapSet.size(state.connected_users) do
        0 ->
          case persist(cancel_persist_timer(state)) do
            {:ok, s} -> s
            {:error, _reason, s} -> s
          end

        _count ->
          state
      end
      |> maybe_schedule_idle_timeout()

    {:reply, :ok, next_state}
  end

  def handle_call({:apply_operation, user_id, operation}, _from, state) do
    case Operation.apply(state.draft, operation) do
      {:ok, draft, inverse_operation} ->
        next_state =
          state
          |> put_draft_update(user_id, inverse_operation, draft)
          |> clear_redo_stack(user_id)
          |> put_save_status(:saving, nil)
          |> schedule_persist(persist_debounce_ms())

        summary = summary(operation, inverse_operation, user_id)
        broadcast(state.version_id, {:draft_updated, next_state.seq, summary})

        {:reply, {:ok, next_state.draft, next_state.seq, undo_state(next_state, user_id)},
         next_state}

      {:error, reason} ->
        broadcast(state.version_id, {:operation_rejected, user_id, reason})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:undo, user_id}, _from, state) do
    case pop_stack_entry(state.undo_stacks, user_id) do
      {:ok, entry, undo_stacks} ->
        case apply_stack_operation(state, user_id, entry, undo_stacks, :undo) do
          {:ok, next_state} ->
            {:reply, {:ok, next_state.draft, next_state.seq, undo_state(next_state, user_id)},
             next_state}

          {:error, reason, next_state} ->
            broadcast(state.version_id, {:undo_rejected, user_id, reason})
            {:reply, {:error, reason}, next_state}
        end

      :empty ->
        {:reply, {:error, :nothing_to_undo}, state}
    end
  end

  def handle_call({:redo, user_id}, _from, state) do
    case pop_stack_entry(state.redo_stacks, user_id) do
      {:ok, entry, redo_stacks} ->
        case apply_stack_operation(state, user_id, entry, redo_stacks, :redo) do
          {:ok, next_state} ->
            {:reply, {:ok, next_state.draft, next_state.seq, undo_state(next_state, user_id)},
             next_state}

          {:error, reason, next_state} ->
            broadcast(state.version_id, {:operation_rejected, user_id, reason})
            {:reply, {:error, reason}, next_state}
        end

      :empty ->
        {:reply, {:error, :nothing_to_redo}, state}
    end
  end

  def handle_call(:persist_now, _from, state) do
    case persist(cancel_persist_timer(state)) do
      {:ok, next_state} ->
        {:reply, {:ok, next_state.draft, next_state.seq}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:get_undo_state, user_id}, _from, state) do
    {:reply, {:ok, undo_state(state, user_id)}, state}
  end

  def handle_call(:get_persistence_state, _from, state) do
    {:reply, {:ok, persistence_state(state)}, state}
  end

  def handle_call(:get_editor_state, _from, state) do
    {:reply, {:ok, state.editor_state}, state}
  end

  def handle_call({:preview_revision, user_id, revision}, _from, state) do
    {:reply, preview_revision_state(state, user_id, revision), state}
  end

  def handle_call({:pin_output, step_id, output_data}, _from, state) do
    editor_state =
      %{
        state.editor_state
        | pinned_outputs: Map.put(state.editor_state.pinned_outputs, step_id, output_data)
      }

    next_state = %{state | editor_state: editor_state}
    broadcast(state.version_id, {:editor_state_changed, editor_state})
    {:reply, {:ok, editor_state}, next_state}
  end

  def handle_call({:unpin_output, step_id}, _from, state) do
    editor_state =
      %{
        state.editor_state
        | pinned_outputs: Map.delete(state.editor_state.pinned_outputs, step_id)
      }

    next_state = %{state | editor_state: editor_state}
    broadcast(state.version_id, {:editor_state_changed, editor_state})
    {:reply, {:ok, editor_state}, next_state}
  end

  def handle_call({:disable_step, step_id}, _from, state) do
    disabled = state.editor_state.disabled_steps

    editor_state =
      %{
        state.editor_state
        | disabled_steps: if(step_id in disabled, do: disabled, else: [step_id | disabled])
      }

    next_state = %{state | editor_state: editor_state}
    broadcast(state.version_id, {:editor_state_changed, editor_state})
    {:reply, {:ok, editor_state}, next_state}
  end

  def handle_call({:enable_step, step_id}, _from, state) do
    editor_state =
      %{
        state.editor_state
        | disabled_steps: Enum.reject(state.editor_state.disabled_steps, &(&1 == step_id))
      }

    next_state = %{state | editor_state: editor_state}
    broadcast(state.version_id, {:editor_state_changed, editor_state})
    {:reply, {:ok, editor_state}, next_state}
  end

  def handle_call({:snapshot, user_id}, _from, state) do
    {:reply,
     {:ok,
      %{
        draft: state.draft,
        seq: state.seq,
        undo_state: undo_state(state, user_id),
        persistence: persistence_state(state),
        editor_state: state.editor_state
      }}, state}
  end

  @impl true
  def handle_info({:persist, ref}, %{persist_timer_ref: ref} = state) do
    next_state =
      case persist(%{state | persist_timer_ref: nil}) do
        {:ok, s} -> s
        {:error, _reason, s} -> s
      end

    {:noreply, next_state}
  end

  def handle_info({:idle_timeout, ref}, %{idle_timer_ref: ref} = state) do
    next_state =
      case persist(%{state | idle_timer_ref: nil}) do
        {:ok, s} -> s
        {:error, _reason, s} -> s
      end

    {:stop, :normal, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{dirty?: true} = state) do
    _ = persist_to_db(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Process lookup ---

  defp ensure_started(version_id, scope) do
    case lookup_pid(version_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        version_id
        |> start_child(scope)
        |> case do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, {:already_present, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp start_child(version_id, scope) do
    DynamicSupervisor.start_child(
      Fizz.Workflows.DraftSessionSupervisor,
      {__MODULE__, version_id: version_id, scope: scope}
    )
  end

  defp lookup_pid(version_id) do
    case Registry.lookup(Fizz.Workflows.DraftSessionRegistry, version_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp ensure_draft(%WorkflowDefinitionVersion{status: :draft}), do: :ok
  defp ensure_draft(%WorkflowDefinitionVersion{}), do: {:error, :not_a_draft}

  # --- Persistence ---

  defp persist(%__MODULE__{} = state) do
    normalized_draft = SlotDefaults.normalize_version(state.draft)
    needs_persist? = state.dirty? or normalized_draft != state.draft
    state = %{state | draft: normalized_draft}

    if not needs_persist? do
      {:ok, put_save_status(state, :saved, nil)}
    else
      persist_dirty(state)
    end
  end

  defp persist_dirty(%__MODULE__{} = state) do
    state = put_save_status(state, :saving, nil)

    case persist_to_db(state) do
      {:ok, next_state} ->
        {:ok,
         next_state
         |> Map.put(:persist_retry_attempt, 0)
         |> put_save_status(:saved, nil)}

      {:error, reason, next_state} ->
        failed_state = put_save_status(next_state, :error, reason)

        failed_state =
          if retryable_persist_error?(reason) do
            attempt = failed_state.persist_retry_attempt + 1

            %{failed_state | persist_retry_attempt: attempt}
            |> schedule_persist(persist_retry_delay_ms(attempt))
          else
            %{failed_state | persist_retry_attempt: 0}
          end

        {:error, reason, failed_state}
    end
  end

  defp persist_to_db(%__MODULE__{} = state) do
    try do
      attrs = draft_snapshot_attrs(state.draft)
      changeset = WorkflowDefinitionVersion.save_changeset(state.draft, attrs)

      case Fizz.Repo.update(changeset) do
        {:ok, persisted_draft} ->
          # Only take updated_at from the DB result. Replacing the full draft
          # with the DB-loaded version causes subtle value changes from Ecto's
          # embed round-trip (float normalisation, map reordering) which makes
          # clients snap back to stale positions on the next operation.
          draft = %{state.draft | updated_at: persisted_draft.updated_at}
          broadcast(state.version_id, {:draft_persisted, state.seq, draft.updated_at})

          {:ok, %{state | draft: draft, dirty?: false, save_error: nil}}

        {:error, reason} ->
          Logger.warning(
            "draft persist failed for version #{state.version_id}: #{inspect(reason)}"
          )

          {:error, reason, state}
      end
    catch
      :exit, reason ->
        Logger.warning("draft persist exited for version #{state.version_id}: #{inspect(reason)}")
        {:error, {:exit, reason}, state}
    end
  end

  # --- Draft / undo operations ---

  defp put_draft_update(state, user_id, inverse_operation, draft) do
    next_seq = state.seq + 1
    entry = stack_entry(inverse_operation, next_seq)

    %{
      state
      | draft: draft,
        seq: next_seq,
        dirty?: true,
        undo_stacks: Map.update(state.undo_stacks, user_id, [entry], &[entry | &1])
    }
  end

  defp clear_redo_stack(state, user_id) do
    %{state | redo_stacks: Map.put(state.redo_stacks, user_id, [])}
  end

  defp apply_stack_operation(state, user_id, entry, updated_stack, direction) do
    case Operation.apply(state.draft, entry.operation) do
      {:ok, draft, inverse_operation} ->
        next_seq = state.seq + 1
        next_entry = stack_entry(inverse_operation, next_seq, entry.label)

        next_state =
          state
          |> Map.put(:draft, draft)
          |> Map.put(:seq, next_seq)
          |> Map.put(:dirty?, true)
          |> put_stack(direction, user_id, updated_stack)
          |> push_inverse_stack_entry(direction, user_id, next_entry)
          |> put_save_status(:saving, nil)
          |> schedule_persist(persist_debounce_ms())

        summary =
          entry.operation
          |> summary(inverse_operation, user_id)
          |> Map.put(:source, direction)

        broadcast(state.version_id, {:draft_updated, next_state.seq, summary})

        {:ok, next_state}

      {:error, reason} ->
        {:error, reason, put_stack(state, direction, user_id, updated_stack)}
    end
  end

  defp put_stack(state, :undo, user_id, updated_stack) do
    %{state | undo_stacks: Map.put(state.undo_stacks, user_id, updated_stack)}
  end

  defp put_stack(state, :redo, user_id, updated_stack) do
    %{state | redo_stacks: Map.put(state.redo_stacks, user_id, updated_stack)}
  end

  defp push_inverse_stack_entry(state, :undo, user_id, entry) do
    %{state | redo_stacks: Map.update(state.redo_stacks, user_id, [entry], &[entry | &1])}
  end

  defp push_inverse_stack_entry(state, :redo, user_id, entry) do
    %{state | undo_stacks: Map.update(state.undo_stacks, user_id, [entry], &[entry | &1])}
  end

  defp pop_stack_entry(stacks, user_id) do
    case Map.get(stacks, user_id, []) do
      [entry | rest] -> {:ok, entry, rest}
      [] -> :empty
    end
  end

  defp stack_entry(operation, seq, label \\ nil) do
    %{
      operation: operation,
      label: label || Map.get(operation, :label),
      seq: seq,
      timestamp: DateTime.utc_now()
    }
  end

  # --- Timers ---

  defp schedule_persist(state, delay_ms) do
    next_state = cancel_persist_timer(state)
    timer_ref = make_ref()
    Process.send_after(self(), {:persist, timer_ref}, delay_ms)
    %{next_state | persist_timer_ref: timer_ref}
  end

  defp maybe_schedule_idle_timeout(%__MODULE__{connected_users: connected_users} = state) do
    case MapSet.size(connected_users) do
      0 -> schedule_idle_timeout(state)
      _count -> cancel_idle_timeout(state)
    end
  end

  defp schedule_idle_timeout(state) do
    next_state = cancel_idle_timeout(state)
    timer_ref = make_ref()
    Process.send_after(self(), {:idle_timeout, timer_ref}, idle_timeout_ms())
    %{next_state | idle_timer_ref: timer_ref}
  end

  defp cancel_idle_timeout(%__MODULE__{idle_timer_ref: nil} = state), do: state

  defp cancel_idle_timeout(%__MODULE__{idle_timer_ref: timer_ref} = state) do
    _ = Process.cancel_timer(timer_ref)
    %{state | idle_timer_ref: nil}
  end

  defp cancel_persist_timer(%__MODULE__{persist_timer_ref: nil} = state), do: state

  defp cancel_persist_timer(%__MODULE__{persist_timer_ref: timer_ref} = state) do
    _ = Process.cancel_timer(timer_ref)
    %{state | persist_timer_ref: nil}
  end

  # --- Connected users ---

  defp put_connected_user(state, user_id) do
    %{state | connected_users: MapSet.put(state.connected_users, user_id)}
  end

  defp remove_connected_user(state, user_id) do
    %{state | connected_users: MapSet.delete(state.connected_users, user_id)}
  end

  # --- Broadcast helpers ---

  defp summary(operation, inverse_operation, user_id) do
    type =
      case operation do
        %{type: operation_type} ->
          operation_type

        %{"type" => operation_type} when is_binary(operation_type) ->
          normalize_summary_type(operation_type)
      end

    base_summary = %{
      type: type,
      user_id: user_id,
      label: Map.get(inverse_operation, :label),
      operation: operation_payload(operation, type)
    }

    case {type, Map.get(inverse_operation, :params, %{})} do
      {:add_step, %{step_id: step_id}} ->
        Map.put(base_summary, :step_id, step_id)

      {:duplicate_steps, %{step_ids: step_ids}} ->
        Map.put(base_summary, :step_ids, step_ids)

      {:add_connection, %{connection_id: connection_id}} ->
        Map.put(base_summary, :connection_id, connection_id)

      {:add_group, %{group_id: group_id}} ->
        Map.put(base_summary, :group_id, group_id)

      _other ->
        base_summary
    end
  end

  defp normalize_summary_type(type) when is_atom(type), do: type

  defp normalize_summary_type(type) when is_binary(type) do
    case type do
      "add_step" -> :add_step
      "remove_step" -> :remove_step
      "update_step" -> :update_step
      "move_step" -> :move_step
      "move_steps" -> :move_steps
      "add_connection" -> :add_connection
      "remove_connection" -> :remove_connection
      "add_group" -> :add_group
      "update_group" -> :update_group
      "remove_group" -> :remove_group
      "set_group_membership" -> :set_group_membership
      "commit_drag_layout" -> :commit_drag_layout
      "duplicate_steps" -> :duplicate_steps
      "tidy_layout" -> :tidy_layout
      "remove_steps" -> :remove_steps
      "restore_steps" -> :restore_steps
      "restore_snapshot" -> :restore_snapshot
      _ -> :unknown
    end
  end

  defp undo_state(state, user_id) do
    undo_stack = Map.get(state.undo_stacks, user_id, [])
    redo_stack = Map.get(state.redo_stacks, user_id, [])

    %{
      canUndo: undo_stack != [],
      canRedo: redo_stack != [],
      undoLabel: stack_label(undo_stack),
      redoLabel: stack_label(redo_stack),
      undoStack: stack_entries(undo_stack),
      redoStack: stack_entries(redo_stack)
    }
  end

  defp stack_label([entry | _rest]), do: entry.label
  defp stack_label([]), do: nil

  defp stack_entries(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, depth} ->
      %{
        id: "revision-#{entry.seq}-#{depth}",
        label: entry.label,
        depth: depth,
        timestamp: encode_datetime(entry.timestamp)
      }
    end)
  end

  defp preview_revision_state(%__MODULE__{} = state, _user_id, :current), do: {:ok, state.draft}

  defp preview_revision_state(%__MODULE__{} = state, user_id, {:undo, depth})
       when is_binary(user_id) and is_integer(depth) and depth > 0 do
    undo_stack = Map.get(state.undo_stacks, user_id, [])

    case Enum.take(undo_stack, depth) do
      entries when length(entries) == depth ->
        Enum.reduce_while(entries, {:ok, state.draft}, fn entry, {:ok, draft} ->
          case Operation.apply(draft, entry.operation) do
            {:ok, preview_draft, _inverse_operation} ->
              {:cont, {:ok, preview_draft}}

            {:error, _reason} = error ->
              {:halt, error}
          end
        end)

      _entries ->
        {:error, :revision_not_found}
    end
  end

  defp preview_revision_state(%__MODULE__{} = state, _user_id, {:version, revision_id})
       when is_binary(revision_id) do
    with {:ok, version} <- Workflows.get_version(state.scope, revision_id),
         :ok <- ensure_same_definition(state.draft, version),
         :ok <- ensure_published(version) do
      {:ok, version}
    end
  end

  defp preview_revision_state(%__MODULE__{}, _user_id, _revision),
    do: {:error, :invalid_revision}

  defp ensure_same_definition(
         %WorkflowDefinitionVersion{workflow_definition_id: workflow_definition_id},
         %WorkflowDefinitionVersion{workflow_definition_id: workflow_definition_id}
       ),
       do: :ok

  defp ensure_same_definition(%WorkflowDefinitionVersion{}, %WorkflowDefinitionVersion{}),
    do: {:error, :revision_not_found}

  defp ensure_published(%WorkflowDefinitionVersion{status: :published}), do: :ok
  defp ensure_published(%WorkflowDefinitionVersion{}), do: {:error, :revision_not_found}

  defp persistence_state(%__MODULE__{} = state) do
    %{status: state.save_status, error: state.save_error}
  end

  defp put_save_status(%__MODULE__{} = state, status, error) do
    next_state = %{state | save_status: status, save_error: error}

    case {state.save_status, state.save_error} do
      {^status, ^error} ->
        next_state

      _previous ->
        broadcast(state.version_id, {:save_status, persistence_state(next_state)})
        next_state
    end
  end

  defp operation_payload(operation, type) when is_map(operation) do
    params =
      case operation do
        %{params: params} when is_map(params) -> params
        %{"params" => params} when is_map(params) -> params
        _ -> %{}
      end

    %{type: type, params: params}
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_datetime(value), do: value

  defp draft_snapshot_attrs(%WorkflowDefinitionVersion{} = draft) do
    %{
      steps: Enum.map(draft.steps, &embed_attrs/1),
      connections: Enum.map(draft.connections, &embed_attrs/1),
      step_groups: Enum.map(draft.step_groups, &embed_attrs/1),
      viewport: draft.viewport,
      settings: draft.settings
    }
  end

  defp embed_attrs(%_{} = embed) do
    embed
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end

  defp broadcast(version_id, message) do
    Phoenix.PubSub.broadcast(Fizz.PubSub, "draft:#{version_id}", message)
  end

  # --- Configuration ---

  defp persist_debounce_ms do
    Application.get_env(:fizz, __MODULE__, [])
    |> Keyword.get(:persist_debounce_ms, @default_persist_debounce_ms)
  end

  defp persist_retry_delay_ms(attempt) do
    base_ms =
      Application.get_env(:fizz, __MODULE__, [])
      |> Keyword.get(:persist_retry_base_ms, @default_persist_retry_base_ms)

    max_ms =
      Application.get_env(:fizz, __MODULE__, [])
      |> Keyword.get(:persist_retry_max_ms, @default_persist_retry_max_ms)

    base_ms
    |> Kernel.*(Integer.pow(2, max(attempt - 1, 0)))
    |> min(max_ms)
  end

  defp idle_timeout_ms do
    Application.get_env(:fizz, __MODULE__, [])
    |> Keyword.get(:idle_timeout_ms, @default_idle_timeout_ms)
  end

  defp retryable_persist_error?(%Ecto.Changeset{}), do: false
  defp retryable_persist_error?(:not_a_draft), do: false
  defp retryable_persist_error?(:project_scope_required), do: false
  defp retryable_persist_error?(:version_not_found), do: false
  defp retryable_persist_error?(errors) when is_list(errors), do: false
  defp retryable_persist_error?(_reason), do: true

  defp via_tuple(registry, version_id) do
    {:via, Registry, {registry, version_id}}
  end
end
