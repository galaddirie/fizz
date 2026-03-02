defmodule Fizz.Collaboration.EditSession.Persistence do
  @moduledoc """
  Handles persistence of edit session state to database.

  Persistence strategy:

  - Operations are buffered in memory
  - Batch-persisted every N seconds or N operations
  - Draft is updated atomically with operation batch
  - Snapshots are taken periodically for faster recovery
  """

  require Logger

  alias Fizz.Repo
  alias Fizz.Workflows.WorkflowDraft
  alias Fizz.Collaboration.EditOperation
  alias Fizz.Collaboration.EditorState

  import Ecto.Query

  @doc "Load pending operations since the last persisted sequence number."
  @spec load_pending_ops(String.t(), integer()) :: {:ok, [EditOperation.t()]} | {:error, term()}
  def load_pending_ops(workflow_id, last_seq) when is_integer(last_seq) and last_seq >= 0 do
    ops =
      EditOperation
      |> where([o], o.workflow_id == ^workflow_id and o.seq > ^last_seq)
      |> order_by([o], asc: o.seq)
      |> Repo.all()

    {:ok, ops}
  end

  @doc "Persist buffered operations and update draft."
  @spec persist(map()) :: {:ok, WorkflowDraft.t()} | {:error, term()}
  def persist(%{workflow_id: _workflow_id, draft: draft, op_buffer: ops, seq: seq} = state) do
    try do
      Repo.transaction(fn ->
        # 1. Batch insert any new operations.
        # DB constraints + on_conflict: :nothing handles duplicates efficiently.
        if ops != [] do
          entries = Enum.map(ops, &operation_to_entry/1)
          Repo.insert_all(EditOperation, entries, on_conflict: :nothing)
        end

        # 2. Update (or create) the draft with current state.
        # Use a fresh DB copy so Ecto can detect changes even when the in-memory
        # draft already reflects the latest edits.
        editor_state_payload =
          case Map.get(state, :editor_state) do
            %EditorState{} = editor_state -> EditorState.to_storage(editor_state)
            _ -> nil
          end

        settings =
          draft.settings
          |> Kernel.||(%{})
          |> Map.put("last_persisted_seq", seq)

        draft_attrs = %{
          steps: Enum.map(draft.steps || [], &ensure_map/1),
          connections: Enum.map(draft.connections || [], &ensure_map/1),
          groups: Enum.map(draft.groups || [], &ensure_map/1),
          settings: settings
        }

        case Repo.get_by(WorkflowDraft, workflow_id: draft.workflow_id) do
          nil ->
            %WorkflowDraft{workflow_id: draft.workflow_id}
            |> WorkflowDraft.changeset(Map.put(draft_attrs, :workflow_id, draft.workflow_id))
            |> maybe_put_editor_state(editor_state_payload)
            |> Repo.insert!()

          db_draft ->
            db_draft
            |> WorkflowDraft.changeset(draft_attrs)
            |> maybe_put_editor_state(editor_state_payload)
            |> Repo.update!()
        end
      end)
      |> case do
        {:ok, persisted_draft} ->
          Logger.info("Persistence.persist: Successfully persisted ops and draft.")
          {:ok, persisted_draft}

        {:error, reason} ->
          Logger.error("Persistence.persist: Transaction failed: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error(
          "Persistence.persist: CRASHED: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        reraise e, __STACKTRACE__
    end
  end

  @doc "Take a snapshot of current state for faster recovery."
  @spec snapshot(String.t(), WorkflowDraft.t(), integer()) ::
          {:ok, WorkflowDraft.t()} | {:error, term()}
  def snapshot(workflow_id, draft, seq) do
    # Could store compressed binary snapshot for very large workflows
    # For now, the draft itself serves as the snapshot
    persist(%{
      workflow_id: workflow_id,
      draft: draft,
      # Clear buffer since we're taking snapshot
      op_buffer: [],
      seq: seq
    })
  end

  defp operation_to_entry(op) do
    %{
      operation_id: op.operation_id,
      seq: op.seq,
      type: op.type,
      payload: op.payload,
      user_id: op.user_id,
      client_seq: op.client_seq,
      workflow_id: op.workflow_id,
      inserted_at: DateTime.utc_now()
    }
  end

  defp ensure_map(%_{} = struct), do: Map.from_struct(struct)
  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(nil), do: nil

  defp maybe_put_editor_state(changeset, nil), do: changeset

  defp maybe_put_editor_state(changeset, editor_state) do
    Ecto.Changeset.put_change(changeset, :editor_state, editor_state)
  end
end
