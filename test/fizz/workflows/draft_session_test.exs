defmodule Fizz.Workflows.DraftSessionTest do
  use Fizz.DataCase, async: false

  import Fizz.AccountsFixtures
  import Fizz.WorkflowsFixtures

  alias Fizz.Accounts.Scope
  alias Fizz.Workflows
  alias Fizz.Workflows.DraftSession

  setup do
    previous_env = Application.get_env(:fizz, DraftSession, [])
    Application.put_env(:fizz, DraftSession, persist_debounce_ms: 25, idle_timeout_ms: 75)

    on_exit(fn ->
      Application.put_env(:fizz, DraftSession, previous_env)
    end)

    :ok
  end

  test "starting a session loads draft from DB" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope, base_snapshot_attrs())

    subscribe_draft(draft.id)
    register_session_cleanup(draft.id)

    assert {:ok, joined_draft, 0, undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert Enum.map(joined_draft.steps, & &1.id) == Enum.map(draft.steps, & &1.id)
    assert Enum.map(joined_draft.connections, & &1.id) == Enum.map(draft.connections, & &1.id)
    assert Enum.map(joined_draft.step_groups, & &1.id) == Enum.map(draft.step_groups, & &1.id)

    assert undo_state == %{
             canUndo: false,
             canRedo: false,
             undoLabel: nil,
             redoLabel: nil,
             undoStack: [],
             redoStack: []
           }

    assert session_pid(draft.id)
    refute_received {:draft_updated, _seq, _summary}
  end

  test "step operations return updated draft" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope, connected_snapshot_attrs())
    original_step_ids = MapSet.new(Enum.map(draft.steps, & &1.id))

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, draft_after_add, 1, undo_state_after_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 420, y: 180}}
             })

    added_step = Enum.find(draft_after_add.steps, &(not MapSet.member?(original_step_ids, &1.id)))
    assert length(draft_after_add.steps) == 3
    assert added_step.position == %{"x" => 420, "y" => 180}
    assert undo_state_after_add.undoLabel == "Add Step"

    assert {:ok, draft_after_remove, 2, _undo_state_after_remove} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :remove_step,
               params: %{step_id: added_step.id}
             })

    assert length(draft_after_remove.steps) == 2
    refute Enum.any?(draft_after_remove.steps, &(&1.id == added_step.id))

    first_step = Enum.at(draft_after_remove.steps, 0)
    second_step = Enum.at(draft_after_remove.steps, 1)

    assert {:ok, draft_after_update, 3, _undo_state_after_update} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :update_step,
               params: %{
                 step_id: first_step.id,
                 changes: %{name: "Renamed Entry", notes: "Updated"}
               }
             })

    updated_first_step = Enum.find(draft_after_update.steps, &(&1.id == first_step.id))
    assert updated_first_step.name == "Renamed Entry"
    assert updated_first_step.notes == "Updated"

    assert {:ok, draft_after_move, 4, _undo_state_after_move} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :move_step,
               params: %{step_id: first_step.id, position: %{x: 300, y: 240}}
             })

    moved_first_step = Enum.find(draft_after_move.steps, &(&1.id == first_step.id))
    assert moved_first_step.position == %{"x" => 300, "y" => 240}

    assert {:ok, draft_after_batch_move, 5, _undo_state_after_batch_move} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :move_steps,
               params: %{
                 step_positions: %{
                   first_step.id => %{x: 30, y: 40},
                   second_step.id => %{x: 90, y: 110}
                 }
               }
             })

    assert Enum.find(draft_after_batch_move.steps, &(&1.id == first_step.id)).position ==
             %{"x" => 30, "y" => 40}

    assert Enum.find(draft_after_batch_move.steps, &(&1.id == second_step.id)).position ==
             %{"x" => 90, "y" => 110}
  end

  test "connection operations return updated draft" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope, base_snapshot_attrs())

    register_session_cleanup(draft.id)

    assert {:ok, joined_draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    source_step = Enum.at(joined_draft.steps, 0)
    target_step = Enum.at(joined_draft.steps, 1)

    assert {:error, {:unknown_target_input, "secondary"}} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_connection,
               params: %{
                 source_step_id: source_step.id,
                 target_step_id: target_step.id,
                 source_output: "main",
                 target_input: "secondary"
               }
             })

    assert {:ok, draft_after_add, 1, _undo_state_after_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_connection,
               params: %{
                 source_step_id: target_step.id,
                 target_step_id: source_step.id,
                 source_output: "main",
                 target_input: "main"
               }
             })

    assert length(draft_after_add.connections) == 2

    added_connection =
      Enum.find(draft_after_add.connections, fn connection ->
        connection.id not in Enum.map(joined_draft.connections, & &1.id)
      end)

    assert added_connection.target_input == "main"

    assert {:ok, draft_after_remove, 2, _undo_state_after_remove} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :remove_connection,
               params: %{connection_id: added_connection.id}
             })

    assert length(draft_after_remove.connections) == 1
    refute Enum.any?(draft_after_remove.connections, &(&1.id == added_connection.id))
  end

  test "group operations return updated draft" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope, base_snapshot_attrs())

    register_session_cleanup(draft.id)

    assert {:ok, joined_draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    first_step = Enum.at(joined_draft.steps, 0)
    second_step = Enum.at(joined_draft.steps, 1)

    assert {:ok, draft_after_add, 1, _undo_state_after_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_group,
               params: %{
                 name: "Primary Group",
                 step_ids: [first_step.id, second_step.id],
                 position: %{x: 50, y: 60, width: 300, height: 200},
                 color: "#0f172a",
                 font_size: 16,
                 step_positions: %{
                   first_step.id => %{x: 10, y: 20},
                   second_step.id => %{x: 120, y: 90}
                 }
               }
             })

    assert length(draft_after_add.step_groups) == 1
    group = hd(draft_after_add.step_groups)
    assert Enum.sort(group.step_ids) == Enum.sort([first_step.id, second_step.id])
    assert group.position == %{"x" => 50, "y" => 60, "width" => 300, "height" => 200}

    assert Enum.find(draft_after_add.steps, &(&1.id == first_step.id)).position == %{
             "x" => 10,
             "y" => 20
           }

    assert {:ok, draft_after_update, 2, _undo_state_after_update} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :update_group,
               params: %{
                 group_id: group.id,
                 changes: %{
                   name: "Renamed Group",
                   collapsed: true,
                   color: "#1d4ed8",
                   font_size: 18,
                   position: %{x: 80, y: 90}
                 }
               }
             })

    updated_group = hd(draft_after_update.step_groups)
    assert updated_group.name == "Renamed Group"
    assert updated_group.collapsed
    assert updated_group.color == "#1d4ed8"
    assert updated_group.font_size == 18
    assert updated_group.position == %{"x" => 80, "y" => 90, "width" => 300, "height" => 200}

    assert {:ok, draft_after_remove, 3, _undo_state_after_remove} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :remove_group,
               params: %{group_id: group.id}
             })

    assert draft_after_remove.step_groups == []

    assert Enum.find(draft_after_remove.steps, &(&1.id == first_step.id)).position ==
             %{"x" => 90, "y" => 110}

    assert Enum.find(draft_after_remove.steps, &(&1.id == second_step.id)).position ==
             %{"x" => 200, "y" => 180}
  end

  test "membership and layout operations return updated draft" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope, grouped_snapshot_attrs())

    register_session_cleanup(draft.id)

    assert {:ok, joined_draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    group_one = Enum.at(joined_draft.step_groups, 0)
    group_two = Enum.at(joined_draft.step_groups, 1)
    first_step = Enum.at(joined_draft.steps, 0)
    second_step = Enum.at(joined_draft.steps, 1)
    third_step = Enum.at(joined_draft.steps, 2)

    assert {:ok, draft_after_membership, 1, _undo_state_after_membership} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :set_group_membership,
               params: %{
                 step_ids: [third_step.id],
                 group_id: group_one.id,
                 step_positions: %{third_step.id => %{x: 45, y: 55}}
               }
             })

    updated_group_one = Enum.find(draft_after_membership.step_groups, &(&1.id == group_one.id))
    assert Enum.sort(updated_group_one.step_ids) == Enum.sort([first_step.id, third_step.id])

    assert Enum.find(draft_after_membership.steps, &(&1.id == third_step.id)).position ==
             %{"x" => 45, "y" => 55}

    assert {:ok, draft_after_commit, 2, _undo_state_after_commit} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :commit_drag_layout,
               params: %{
                 txn_id: "txn_commit",
                 groups: [
                   %{
                     group_id: group_one.id,
                     position: %{x: 120, y: 130, width: 210, height: 220}
                   }
                 ],
                 step_positions: %{
                   first_step.id => %{x: 15, y: 25},
                   second_step.id => %{x: 75, y: 65}
                 },
                 group_id_by_step_id: %{second_step.id => group_one.id}
               }
             })

    committed_group_one = Enum.find(draft_after_commit.step_groups, &(&1.id == group_one.id))
    committed_group_two = Enum.find(draft_after_commit.step_groups, &(&1.id == group_two.id))

    assert committed_group_one.position == %{
             "x" => 120,
             "y" => 130,
             "width" => 210,
             "height" => 220
           }

    assert Enum.sort(committed_group_one.step_ids) ==
             Enum.sort([first_step.id, second_step.id, third_step.id])

    assert committed_group_two.step_ids == []

    assert Enum.find(draft_after_commit.steps, &(&1.id == second_step.id)).position ==
             %{"x" => 75, "y" => 65}

    assert {:ok, draft_after_tidy, 3, undo_state_after_tidy} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :tidy_layout,
               params: %{
                 steps: [%{step_id: first_step.id, position: %{x: 5, y: 5}}],
                 groups: [
                   %{
                     group_id: group_one.id,
                     position: %{x: 150, y: 160, width: 240, height: 250}
                   }
                 ],
                 label: "Tidy Up Workflow"
               }
             })

    assert Enum.find(draft_after_tidy.steps, &(&1.id == first_step.id)).position ==
             %{"x" => 5, "y" => 5}

    assert Enum.find(draft_after_tidy.step_groups, &(&1.id == group_one.id)).position ==
             %{"x" => 150, "y" => 160, "width" => 240, "height" => 250}

    assert undo_state_after_tidy.undoLabel == "Tidy Up Workflow"
  end

  test "duplicate_steps returns updated draft" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope, connected_grouped_snapshot_attrs())

    register_session_cleanup(draft.id)

    assert {:ok, joined_draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    first_step = Enum.at(joined_draft.steps, 0)
    second_step = Enum.at(joined_draft.steps, 1)
    group = hd(joined_draft.step_groups)

    assert {:ok, draft_after_duplicate, 1, undo_state_after_duplicate} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :duplicate_steps,
               params: %{
                 step_ids: [first_step.id, second_step.id],
                 position_by_step_id: %{
                   first_step.id => %{x: 150, y: 25},
                   second_step.id => %{x: 260, y: 110}
                 },
                 group_id_by_step_id: %{
                   first_step.id => group.id,
                   second_step.id => group.id
                 }
               }
             })

    assert length(draft_after_duplicate.steps) == 4
    assert length(draft_after_duplicate.connections) == 2
    assert undo_state_after_duplicate.undoLabel == "Duplicate Steps"

    new_steps =
      Enum.reject(draft_after_duplicate.steps, fn step ->
        step.id in [first_step.id, second_step.id]
      end)

    new_step_ids = Enum.map(new_steps, & &1.id)
    assert Enum.sort(hd(draft_after_duplicate.step_groups).step_ids) |> length() == 4
    assert Enum.find(new_steps, &(&1.position == %{"x" => 150, "y" => 25}))
    assert Enum.find(new_steps, &(&1.position == %{"x" => 260, "y" => 110}))

    duplicated_connection =
      Enum.find(draft_after_duplicate.connections, fn connection ->
        connection.id not in Enum.map(joined_draft.connections, & &1.id)
      end)

    assert duplicated_connection.source_step_id in new_step_ids
    assert duplicated_connection.target_step_id in new_step_ids
  end

  test "undo reverses the last operation" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope)

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, draft_after_add, 1, _undo_state_after_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 10, y: 20}}
             })

    added_step = hd(draft_after_add.steps)

    assert {:ok, draft_after_undo, 2, undo_state_after_undo} =
             DraftSession.undo(draft.id, scope.user.id)

    assert draft_after_undo.steps == []
    refute Enum.any?(draft_after_undo.steps, &(&1.id == added_step.id))
    assert undo_state_after_undo.canUndo == false
    assert undo_state_after_undo.canRedo == true
    assert undo_state_after_undo.redoLabel == "Add Step"
  end

  test "redo reapplies after undo" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope)

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, _draft_after_add, 1, _undo_state_after_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 10, y: 20}}
             })

    assert {:ok, _draft_after_undo, 2, _undo_state_after_undo} =
             DraftSession.undo(draft.id, scope.user.id)

    assert {:ok, draft_after_redo, 3, undo_state_after_redo} =
             DraftSession.redo(draft.id, scope.user.id)

    assert length(draft_after_redo.steps) == 1
    assert undo_state_after_redo.canUndo == true
    assert undo_state_after_redo.canRedo == false
    assert undo_state_after_redo.undoLabel == "Add Step"
  end

  test "undo state exposes revision summaries and preview_revision replays undo depth" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope)

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, first_draft, 1, _undo_state_after_first_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 10, y: 20}}
             })

    first_added_step = hd(first_draft.steps)

    assert {:ok, second_draft, 2, undo_state_after_second_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 40, y: 50}}
             })

    second_added_step =
      Enum.find(second_draft.steps, fn step -> step.id != first_added_step.id end)

    [latest_revision, previous_revision] = undo_state_after_second_add.undoStack

    assert latest_revision.depth == 1
    assert latest_revision.label == "Add Step"
    assert is_binary(latest_revision.id)
    assert is_binary(latest_revision.timestamp)

    assert previous_revision.depth == 2
    assert previous_revision.label == "Add Step"

    assert {:ok, preview_after_one_undo} =
             DraftSession.preview_revision(draft.id, scope.user.id, {:undo, 1})

    assert length(preview_after_one_undo.steps) == 1
    refute Enum.any?(preview_after_one_undo.steps, &(&1.id == second_added_step.id))

    assert {:ok, preview_after_two_undos} =
             DraftSession.preview_revision(draft.id, scope.user.id, {:undo, 2})

    assert preview_after_two_undos.steps == []
    refute Enum.any?(preview_after_two_undos.steps, &(&1.id == first_added_step.id))
  end

  test "undo history is capped by configured depth" do
    previous_env = Application.get_env(:fizz, DraftSession, [])
    Application.put_env(:fizz, DraftSession, Keyword.merge(previous_env, history_limit: 2))

    on_exit(fn ->
      Application.put_env(:fizz, DraftSession, previous_env)
    end)

    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope)

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    for index <- 1..3 do
      assert {:ok, _draft, ^index, _undo_state} =
               DraftSession.apply_operation(draft.id, scope.user.id, %{
                 type: :add_step,
                 params: %{type_id: "debug", position: %{x: index * 20, y: index * 20}}
               })
    end

    assert {:ok, undo_state} = DraftSession.get_undo_state(draft.id, scope.user.id)
    assert Enum.map(undo_state.undoStack, & &1.depth) == [1, 2]

    assert {:error, :revision_not_found} =
             DraftSession.preview_revision(draft.id, scope.user.id, {:undo, 3})
  end

  test "restore_snapshot applies a revision as a single undoable operation" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope)

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    snapshot = %{
      steps: [
        step(%{
          name: "Restored Step",
          position: %{"x" => 200, "y" => 220}
        })
      ],
      connections: [],
      step_groups: [],
      viewport: %{"x" => 12, "y" => 24, "zoom" => 1.25},
      settings: %{"mode" => "restored"}
    }

    assert {:ok, restored_draft, 1, undo_state_after_restore} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :restore_snapshot,
               params: %{snapshot: snapshot, label: "Apply v1"}
             })

    assert Enum.map(restored_draft.steps, & &1.name) == ["Restored Step"]
    assert restored_draft.viewport == %{"x" => 12, "y" => 24, "zoom" => 1.25}
    assert restored_draft.settings == %{"mode" => "restored"}
    assert undo_state_after_restore.undoLabel == "Apply v1"

    assert {:ok, reverted_draft, 2, undo_state_after_undo} =
             DraftSession.undo(draft.id, scope.user.id)

    assert reverted_draft.steps == []
    assert reverted_draft.viewport == %{"x" => 0, "y" => 0, "zoom" => 1.0}
    assert reverted_draft.settings == %{}
    assert undo_state_after_undo.redoLabel == "Apply v1"
  end

  test "undo conflict pops stack and rejects" do
    scope = project_scope_fixture()
    second_scope = secondary_scope(scope)
    %{draft: draft} = draft_fixture(scope)
    first_user_id = scope.user.id

    subscribe_draft(draft.id)
    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, second_scope, second_scope.user.id)

    assert {:ok, draft_after_add, 1, _undo_state_after_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 10, y: 20}}
             })

    added_step = hd(draft_after_add.steps)

    assert {:ok, _draft_after_remove, 2, _undo_state_after_remove} =
             DraftSession.apply_operation(draft.id, second_scope.user.id, %{
               type: :remove_step,
               params: %{step_id: added_step.id}
             })

    assert {:error, :step_not_found} = DraftSession.undo(draft.id, first_user_id)
    assert_receive {:undo_rejected, ^first_user_id, :step_not_found}

    assert {:ok, undo_state} = DraftSession.get_undo_state(draft.id, first_user_id)

    assert undo_state == %{
             canUndo: false,
             canRedo: false,
             undoLabel: nil,
             redoLabel: nil,
             undoStack: [],
             redoStack: []
           }
  end

  test "new operation clears redo stack" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope)

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, _draft_after_add, 1, _undo_state_after_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 10, y: 20}}
             })

    assert {:ok, _draft_after_undo, 2, undo_state_after_undo} =
             DraftSession.undo(draft.id, scope.user.id)

    assert undo_state_after_undo.canRedo

    assert {:ok, _draft_after_second_add, 3, undo_state_after_second_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 40, y: 50}}
             })

    assert undo_state_after_second_add.canUndo
    assert undo_state_after_second_add.canRedo == false
    assert undo_state_after_second_add.redoLabel == nil
  end

  test "periodic persist writes to DB when dirty" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope)
    user_id = scope.user.id

    subscribe_draft(draft.id)
    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, user_id)

    assert {:ok, _draft_after_add, 1, _undo_state_after_add} =
             DraftSession.apply_operation(draft.id, user_id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 10, y: 20}}
             })

    assert_receive {:save_status, %{status: :saving, error: nil}}
    assert_receive {:draft_updated, 1, %{type: :add_step, user_id: ^user_id}}
    assert_receive {:draft_persisted, 1, %DateTime{}}
    assert_receive {:save_status, %{status: :saved, error: nil}}

    assert {:ok, persisted_draft} = Workflows.get_version(scope, draft.id)
    assert length(persisted_draft.steps) == 1
  end

  test "persistence state reports saving while debounce is pending" do
    previous_env = Application.get_env(:fizz, DraftSession, [])

    Application.put_env(:fizz, DraftSession,
      persist_debounce_ms: 500,
      idle_timeout_ms: 75,
      persist_retry_base_ms: 25,
      persist_retry_max_ms: 50
    )

    on_exit(fn ->
      Application.put_env(:fizz, DraftSession, previous_env)
    end)

    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope)

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, _draft_after_add, 1, _undo_state_after_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 10, y: 20}}
             })

    assert {:ok, %{status: :saving, error: nil}} = DraftSession.get_persistence_state(draft.id)
  end

  test "idle timeout shuts down after last user leaves" do
    previous_env = Application.get_env(:fizz, DraftSession, [])
    Application.put_env(:fizz, DraftSession, persist_debounce_ms: 500, idle_timeout_ms: 60)

    on_exit(fn ->
      Application.put_env(:fizz, DraftSession, previous_env)
    end)

    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope)

    subscribe_draft(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    pid = session_pid(draft.id)
    ref = Process.monitor(pid)

    assert {:ok, _draft_after_add, 1, _undo_state_after_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 10, y: 20}}
             })

    assert :ok = DraftSession.leave(draft.id, scope.user.id)
    assert_receive {:draft_persisted, 1, %DateTime{}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:ok, persisted_draft} = Workflows.get_version(scope, draft.id)
    assert length(persisted_draft.steps) == 1
  end

  test "multiple users have independent undo stacks" do
    scope = project_scope_fixture()
    second_scope = secondary_scope(scope)
    %{draft: draft} = draft_fixture(scope)

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, second_scope, second_scope.user.id)

    assert {:ok, draft_after_first_add, 1, _undo_state_after_first_add} =
             DraftSession.apply_operation(draft.id, scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 10, y: 20}}
             })

    first_step = hd(draft_after_first_add.steps)

    assert {:ok, _draft_after_second_add, 2, _undo_state_after_second_add} =
             DraftSession.apply_operation(draft.id, second_scope.user.id, %{
               type: :add_step,
               params: %{type_id: "debug", position: %{x: 80, y: 90}}
             })

    assert {:ok, first_user_undo_state} = DraftSession.get_undo_state(draft.id, scope.user.id)

    assert {:ok, second_user_undo_state} =
             DraftSession.get_undo_state(draft.id, second_scope.user.id)

    assert first_user_undo_state.canUndo
    assert second_user_undo_state.canUndo

    assert {:ok, draft_after_first_undo, 3, _undo_state_after_first_undo} =
             DraftSession.undo(draft.id, scope.user.id)

    refute Enum.any?(draft_after_first_undo.steps, &(&1.id == first_step.id))
    assert length(draft_after_first_undo.steps) == 1

    assert {:ok, second_user_undo_state_after_first_undo} =
             DraftSession.get_undo_state(draft.id, second_scope.user.id)

    assert second_user_undo_state_after_first_undo.canUndo
  end

  test "overlapping commit_drag_layout operations converge by applied seq order" do
    scope = project_scope_fixture()
    second_scope = secondary_scope(scope)
    %{draft: draft} = draft_fixture(scope, grouped_snapshot_attrs())

    register_session_cleanup(draft.id)

    assert {:ok, joined_draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, second_scope, second_scope.user.id)

    group = Enum.at(joined_draft.step_groups, 0)
    step = Enum.at(joined_draft.steps, 0)

    first_payload = %{
      type: :commit_drag_layout,
      params: %{
        txn_id: "txn_commit_one",
        groups: [
          %{
            group_id: group.id,
            position: %{x: 120, y: 140, width: 420, height: 300}
          }
        ],
        step_positions: %{
          step.id => %{x: 20, y: 25}
        },
        group_id_by_step_id: %{}
      }
    }

    second_payload = %{
      type: :commit_drag_layout,
      params: %{
        txn_id: "txn_commit_two",
        groups: [
          %{
            group_id: group.id,
            position: %{x: 180, y: 220, width: 460, height: 340}
          }
        ],
        step_positions: %{
          step.id => %{x: 65, y: 70}
        },
        group_id_by_step_id: %{}
      }
    }

    task_one =
      Task.async(fn ->
        DraftSession.apply_operation(draft.id, scope.user.id, first_payload)
      end)

    task_two =
      Task.async(fn ->
        DraftSession.apply_operation(draft.id, second_scope.user.id, second_payload)
      end)

    assert {:ok, _draft_after_first, seq_one, _undo_state_after_first} = Task.await(task_one)
    assert {:ok, _draft_after_second, seq_two, _undo_state_after_second} = Task.await(task_two)
    assert seq_one != seq_two

    {expected_group_position, expected_step_position} =
      if seq_one > seq_two do
        {%{"x" => 120, "y" => 140, "width" => 420, "height" => 300}, %{"x" => 20, "y" => 25}}
      else
        {%{"x" => 180, "y" => 220, "width" => 460, "height" => 340}, %{"x" => 65, "y" => 70}}
      end

    assert {:ok, current_draft, current_seq, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    current_group = Enum.find(current_draft.step_groups, &(&1.id == group.id))
    current_step = Enum.find(current_draft.steps, &(&1.id == step.id))

    assert current_seq == max(seq_one, seq_two)
    assert current_group.position == expected_group_position
    assert current_step.position == expected_step_position
  end

  test "operation rejection does not modify state or increment seq" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope, base_snapshot_attrs())
    user_id = scope.user.id

    subscribe_draft(draft.id)
    register_session_cleanup(draft.id)

    assert {:ok, joined_draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, user_id)

    first_step = hd(joined_draft.steps)

    assert {:error, :self_connection} =
             DraftSession.apply_operation(draft.id, user_id, %{
               type: :add_connection,
               params: %{
                 source_step_id: first_step.id,
                 target_step_id: first_step.id
               }
             })

    assert_receive {:operation_rejected, ^user_id, :self_connection}
    refute_receive {:draft_updated, _seq, _summary}

    assert {:ok, current_draft, current_seq, undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, user_id)

    assert current_seq == 0
    assert current_draft.steps == joined_draft.steps
    assert current_draft.connections == joined_draft.connections

    assert undo_state == %{
             canUndo: false,
             canRedo: false,
             undoLabel: nil,
             redoLabel: nil,
             undoStack: [],
             redoStack: []
           }
  end

  test "editor_state is shared across users and survives reconnection" do
    scope = project_scope_fixture()
    second_scope = secondary_scope(scope)
    %{draft: draft} = draft_fixture(scope, base_snapshot_attrs())
    first_step_id = hd(draft.steps).id

    subscribe_draft(draft.id)
    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert editor_state == %{pinned_outputs: %{}, disabled_steps: [], step_locks: %{}}

    # Pin an output
    assert {:ok, editor_state} =
             DraftSession.pin_output(draft.id, first_step_id, %{"result" => 42})

    assert editor_state.pinned_outputs == %{first_step_id => %{"result" => 42}}
    assert_receive {:editor_state_changed, ^editor_state}

    # Disable a step
    assert {:ok, editor_state} = DraftSession.disable_step(draft.id, first_step_id)
    assert first_step_id in editor_state.disabled_steps
    assert_receive {:editor_state_changed, ^editor_state}

    # Second user sees shared state on join
    assert {:ok, _draft, 0, _undo_state, shared_editor_state} =
             DraftSession.join(draft.id, second_scope, second_scope.user.id)

    assert shared_editor_state.pinned_outputs == %{first_step_id => %{"result" => 42}}
    assert first_step_id in shared_editor_state.disabled_steps

    # First user leaves and rejoins — state persists
    :ok = DraftSession.leave(draft.id, scope.user.id)

    assert {:ok, _draft, _seq, _undo_state, reconnected_editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert reconnected_editor_state.pinned_outputs == %{first_step_id => %{"result" => 42}}
    assert first_step_id in reconnected_editor_state.disabled_steps

    # Unpin and enable
    assert {:ok, editor_state} = DraftSession.unpin_output(draft.id, first_step_id)
    assert editor_state.pinned_outputs == %{}

    assert {:ok, editor_state} = DraftSession.enable_step(draft.id, first_step_id)
    assert editor_state.disabled_steps == []
  end

  test "disable_step is idempotent" do
    scope = project_scope_fixture()
    %{draft: draft} = draft_fixture(scope, base_snapshot_attrs())
    first_step_id = hd(draft.steps).id

    register_session_cleanup(draft.id)

    assert {:ok, _draft, 0, _undo_state, _editor_state} =
             DraftSession.join(draft.id, scope, scope.user.id)

    assert {:ok, editor_state} = DraftSession.disable_step(draft.id, first_step_id)
    assert {:ok, editor_state2} = DraftSession.disable_step(draft.id, first_step_id)
    assert editor_state.disabled_steps == editor_state2.disabled_steps
    assert length(editor_state2.disabled_steps) == 1
  end

  defp draft_fixture(scope, snapshot_attrs \\ nil) do
    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Workflow #{System.unique_integer([:positive])}",
        description: "Draft session"
      })

    case snapshot_attrs do
      nil ->
        %{definition: definition, draft: draft}

      attrs ->
        {:ok, saved_draft} = Workflows.save_draft(scope, draft, attrs)
        %{definition: definition, draft: saved_draft}
    end
  end

  defp base_snapshot_attrs do
    entry_step =
      step(%{
        name: "Entry",
        position: %{"x" => 10, "y" => 20}
      })

    debug_step =
      step(%{
        name: "Debug",
        position: %{"x" => 200, "y" => 150}
      })

    snapshot_attrs(%{
      steps: [entry_step, debug_step],
      connections: [
        connection(%{
          source_step_id: entry_step.id,
          target_step_id: debug_step.id
        })
      ]
    })
  end

  defp connected_snapshot_attrs do
    base_snapshot_attrs()
  end

  defp grouped_snapshot_attrs do
    first_step =
      step(%{
        name: "First",
        position: %{"x" => 10, "y" => 20}
      })

    second_step =
      step(%{
        name: "Second",
        position: %{"x" => 30, "y" => 40}
      })

    third_step =
      step(%{
        name: "Third",
        position: %{"x" => 220, "y" => 180}
      })

    group_one = %{
      id: Ecto.UUID.generate(),
      name: "Group One",
      step_ids: [first_step.id],
      position: %{"x" => 100, "y" => 100, "width" => 200, "height" => 200},
      color: "#0f172a",
      font_size: 14,
      collapsed: false
    }

    group_two = %{
      id: Ecto.UUID.generate(),
      name: "Group Two",
      step_ids: [second_step.id],
      position: %{"x" => 300, "y" => 100, "width" => 200, "height" => 200},
      color: "#1d4ed8",
      font_size: 14,
      collapsed: false
    }

    snapshot_attrs(%{
      steps: [first_step, second_step, third_step],
      connections: [],
      step_groups: [group_one, group_two]
    })
  end

  defp connected_grouped_snapshot_attrs do
    first_step =
      step(%{
        name: "First",
        position: %{"x" => 10, "y" => 20}
      })

    second_step =
      step(%{
        name: "Second",
        position: %{"x" => 110, "y" => 80}
      })

    group = %{
      id: Ecto.UUID.generate(),
      name: "Group",
      step_ids: [first_step.id, second_step.id],
      position: %{"x" => 100, "y" => 100, "width" => 250, "height" => 220},
      color: "#0f172a",
      font_size: 14,
      collapsed: false
    }

    snapshot_attrs(%{
      steps: [first_step, second_step],
      connections: [
        connection(%{
          source_step_id: first_step.id,
          target_step_id: second_step.id
        })
      ],
      step_groups: [group]
    })
  end

  defp secondary_scope(scope) do
    second_user = user_fixture()

    Scope.for_user(second_user)
    |> Scope.with_organization_id(scope.organization_id)
    |> Scope.with_organization_role(scope.organization_role)
    |> Scope.with_project(scope.project)
    |> Scope.with_project_role(scope.project_role)
  end

  defp subscribe_draft(version_id) do
    Phoenix.PubSub.subscribe(Fizz.PubSub, "draft:#{version_id}")
  end

  defp register_session_cleanup(version_id) do
    on_exit(fn ->
      case Registry.lookup(Fizz.Workflows.DraftSessionRegistry, version_id) do
        [{pid, _value}] -> GenServer.stop(pid, :normal)
        [] -> :ok
      end
    end)
  end

  defp session_pid(version_id) do
    case Registry.lookup(Fizz.Workflows.DraftSessionRegistry, version_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
