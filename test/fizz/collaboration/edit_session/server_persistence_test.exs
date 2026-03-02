defmodule Fizz.Collaboration.EditSession.ServerPersistenceTest do
  use Fizz.DataCase, async: false

  import Ecto.Query
  import Fizz.AccountsFixtures

  alias Fizz.Accounts.Scope
  alias Fizz.Collaboration.EditSession.Server
  alias Fizz.Repo
  alias Fizz.Workflows
  alias Fizz.Workflows.WorkflowDraft

  test "persist_sync refreshes the session draft timestamp from the database" do
    user = user_fixture()
    org_scope = organization_scope_fixture(user: user)
    workspace = workspace_fixture(org_scope)

    scope =
      org_scope
      |> Scope.with_workspace(workspace)
      |> Scope.with_workspace_role(:admin)

    workflow = workflow_fixture!(scope)
    stale_updated_at = DateTime.add(DateTime.utc_now(), -3600, :second)

    Repo.update_all(
      from(d in WorkflowDraft, where: d.workflow_id == ^workflow.id),
      set: [updated_at: stale_updated_at]
    )

    _server_pid = start_supervised!({Server, workflow_id: workflow.id, scope: scope})

    assert {:ok, %{type: :full_sync, draft: initial_draft}} = Server.get_sync_state(workflow.id)
    assert DateTime.compare(initial_draft.updated_at, stale_updated_at) == :eq

    assert {:ok, %{status: :applied}} =
             Server.apply_operation(workflow.id, update_step_position_operation(user.id))

    assert :ok = Server.persist_sync(workflow.id)

    persisted_draft = Repo.get_by!(WorkflowDraft, workflow_id: workflow.id)

    assert {:ok, %{type: :full_sync, draft: synced_draft}} = Server.get_sync_state(workflow.id)
    assert DateTime.compare(persisted_draft.updated_at, stale_updated_at) == :gt
    assert DateTime.compare(synced_draft.updated_at, stale_updated_at) == :gt
    assert DateTime.compare(synced_draft.updated_at, persisted_draft.updated_at) == :eq
  end

  defp update_step_position_operation(user_id) do
    %{
      id: Ecto.UUID.generate(),
      type: :update_step_position,
      payload: %{
        step_id: "step_a",
        position: %{x: 180, y: 220}
      },
      user_id: user_id,
      client_seq: nil
    }
  end

  defp workflow_fixture!(scope) do
    {:ok, workflow} =
      Workflows.create_workflow(scope, %{
        name: "Persisted Draft #{System.unique_integer([:positive])}",
        description: "persistence test"
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
          }
        ],
        connections: [],
        groups: []
      })

    workflow
  end
end
