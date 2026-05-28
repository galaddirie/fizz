defmodule Fizz.Workflows.DraftsFacadeTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows

  setup do
    previous_env = Application.get_env(:fizz, Fizz.Workflows.DraftSession, [])

    Application.put_env(:fizz, Fizz.Workflows.DraftSession,
      persist_debounce_ms: 500,
      idle_timeout_ms: 75
    )

    on_exit(fn ->
      Application.put_env(:fizz, Fizz.Workflows.DraftSession, previous_env)
    end)

    :ok
  end

  describe "draft session facade" do
    test "joins, mutates, reads, persists, previews, and leaves a draft session" do
      scope = project_scope_fixture()
      existing_step = step(%{name: "Existing"})
      %{draft: draft} = draft_fixture(scope, snapshot_attrs(%{steps: [existing_step]}))
      register_session_cleanup(draft.id)

      assert {:ok, joined_draft, 0, undo_state, editor_state} =
               Workflows.join_draft_session(draft.id, scope, scope.user.id)

      assert joined_draft.id == draft.id
      refute undo_state.canUndo
      assert editor_state.pinned_outputs == %{}

      assert {:ok, draft_after_add, 1, undo_state_after_add} =
               Workflows.apply_draft_operation(draft.id, scope.user.id, %{
                 type: :add_step,
                 params: %{type_id: "debug", position: %{x: 420, y: 180}}
               })

      assert length(draft_after_add.steps) == 2
      assert undo_state_after_add.canUndo

      added_step = Enum.find(draft_after_add.steps, &(&1.id != existing_step.id))

      assert {:ok, undo_state} = Workflows.get_draft_undo_state(draft.id, scope.user.id)
      assert undo_state.undoLabel == "Add Step"

      assert {:ok, editor_state} =
               Workflows.pin_draft_step_output(draft.id, added_step.id, %{"result" => 42})

      assert editor_state.pinned_outputs[added_step.id] == %{"result" => 42}

      assert {:ok,
              %{
                draft: snapshot_draft,
                seq: 1,
                undo_state: snapshot_undo_state,
                persistence: %{status: :saving},
                editor_state: snapshot_editor_state
              }} = Workflows.get_draft_snapshot(draft.id, scope.user.id)

      assert snapshot_draft.id == draft.id
      assert snapshot_undo_state.canUndo
      assert snapshot_editor_state.pinned_outputs[added_step.id] == %{"result" => 42}

      assert {:ok, preview_draft} =
               Workflows.preview_draft_revision(draft.id, scope.user.id, {:undo, 1})

      assert Enum.map(preview_draft.steps, & &1.id) == [existing_step.id]

      assert {:ok, persisted_draft, 1} = Workflows.persist_draft_now(draft.id)
      assert persisted_draft.id == draft.id

      assert {:ok, %{status: :saved, error: nil}} =
               Workflows.get_draft_persistence_state(draft.id)

      assert {:ok, draft_after_undo, 2, undo_state_after_undo} =
               Workflows.undo_draft_operation(draft.id, scope.user.id)

      assert Enum.map(draft_after_undo.steps, & &1.id) == [existing_step.id]
      assert undo_state_after_undo.canRedo

      assert {:ok, draft_after_redo, 3, undo_state_after_redo} =
               Workflows.redo_draft_operation(draft.id, scope.user.id)

      assert length(draft_after_redo.steps) == 2
      assert undo_state_after_redo.canUndo

      assert :ok = Workflows.leave_draft_session(draft.id, scope.user.id)
    end

    test "read operations return not found before a session is joined" do
      assert {:error, :not_found} =
               Workflows.get_draft_persistence_state(Ecto.UUID.generate())

      assert {:error, :not_found} =
               Workflows.get_draft_undo_state(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  defp register_session_cleanup(version_id) do
    on_exit(fn ->
      case Registry.lookup(Fizz.Workflows.DraftSessionRegistry, version_id) do
        [{pid, _value}] -> GenServer.stop(pid, :normal)
        [] -> :ok
      end
    end)
  end
end
