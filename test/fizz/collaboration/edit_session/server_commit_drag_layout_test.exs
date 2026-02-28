defmodule Fizz.Collaboration.EditSession.ServerCommitDragLayoutTest do
  use Fizz.DataCase, async: false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts.{Scope, Workspace, WorkspaceMembership}
  alias Fizz.Collaboration.EditSession.Server
  alias Fizz.Repo
  alias Fizz.Workflows

  test "overlapping drag layout commits converge by server seq order" do
    user_one = user_fixture()
    user_two = user_fixture()
    workspace = workspace_fixture!(user_one, [user_two])
    scope = scoped_workspace_access(user_one, workspace)
    workflow = workflow_fixture!(scope)
    _server_pid = start_supervised!({Server, workflow_id: workflow.id, scope: scope})

    op_one =
      commit_drag_layout_operation(user_one.id, "txn-server-1", %{
        group: %{x: 120, y: 140, width: 420, height: 300},
        step: %{x: 20, y: 25}
      })

    op_two =
      commit_drag_layout_operation(user_two.id, "txn-server-2", %{
        group: %{x: 180, y: 220, width: 460, height: 340},
        step: %{x: 65, y: 70}
      })

    task_one = Task.async(fn -> Server.apply_operation(workflow.id, op_one) end)
    task_two = Task.async(fn -> Server.apply_operation(workflow.id, op_two) end)

    assert {:ok, %{seq: seq_one, status: :applied}} = Task.await(task_one)
    assert {:ok, %{seq: seq_two, status: :applied}} = Task.await(task_two)
    assert seq_one != seq_two

    assert {:ok, %{type: :full_sync, draft: draft, seq: final_seq}} =
             Server.get_sync_state(workflow.id)

    assert final_seq == max(seq_one, seq_two)

    expected_payload =
      if seq_one > seq_two do
        op_one.payload
      else
        op_two.payload
      end

    expected_group_position =
      expected_payload
      |> Map.get(:groups)
      |> List.first()
      |> Map.get(:position)

    expected_step_position =
      expected_payload
      |> Map.get(:step_positions)
      |> Map.get("step_a")

    assert group_position_for(draft, "group_a") == expected_group_position
    assert step_position_for(draft, "step_a") == expected_step_position
  end

  defp commit_drag_layout_operation(user_id, txn_id, %{group: group_position, step: step_position}) do
    %{
      id: Ecto.UUID.generate(),
      type: :commit_drag_layout,
      payload: %{
        txn_id: txn_id,
        base_seq: 0,
        groups: [%{group_id: "group_a", position: group_position}],
        step_positions: %{"step_a" => step_position},
        group_id_by_step_id: %{}
      },
      user_id: user_id,
      client_seq: nil
    }
  end

  defp group_position_for(draft, group_id) do
    draft.groups
    |> List.wrap()
    |> Enum.find(fn group -> Map.get(group, :id) == group_id end)
    |> Map.get(:position)
  end

  defp step_position_for(draft, step_id) do
    draft.steps
    |> List.wrap()
    |> Enum.find(fn step -> Map.get(step, :id) == step_id end)
    |> Map.get(:position)
  end

  defp workflow_fixture!(scope) do
    {:ok, workflow} =
      Workflows.create_workflow(scope, %{
        name: "Server Commit Layout #{System.unique_integer([:positive])}",
        description: "server test"
      })

    {:ok, _draft} =
      Workflows.update_workflow_draft(scope, workflow, %{
        steps: [
          %{
            id: "step_a",
            type_id: "math",
            name: "Step A",
            config: %{},
            position: %{x: 60, y: 60}
          },
          %{
            id: "step_b",
            type_id: "math",
            name: "Step B",
            config: %{},
            position: %{x: 150, y: 130}
          }
        ],
        connections: [],
        groups: [
          %{
            id: "group_a",
            name: "Group A",
            step_ids: ["step_a", "step_b"],
            output_step_id: "step_a",
            position: %{x: 100, y: 100, width: 320, height: 240},
            color: nil,
            collapsed: false
          }
        ]
      })

    workflow
  end

  defp workspace_fixture!(owner_user, additional_users) do
    unique = System.unique_integer([:positive])

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        name: "Server Commit Workspace #{unique}",
        slug: "server-commit-workspace-#{unique}",
        workos_organization_id: "org_#{unique}"
      })
      |> Repo.insert!()

    member_ids = [owner_user.id | Enum.map(additional_users, & &1.id)]

    Enum.each(member_ids, fn user_id ->
      %WorkspaceMembership{workspace_id: workspace.id, user_id: user_id}
      |> WorkspaceMembership.changeset(%{role: :admin})
      |> Repo.insert!()
    end)

    workspace
  end

  defp scoped_workspace_access(user, workspace) do
    Scope.for_user(user)
    |> Scope.with_organization_id(workspace.workos_organization_id)
    |> Scope.with_organization_role(:owner)
    |> Scope.with_workspace(workspace)
    |> Scope.with_workspace_role(:admin)
  end
end
