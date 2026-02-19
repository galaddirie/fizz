defmodule Fizz.Collaboration.EditSession.SupervisorTest do
  use Fizz.DataCase, async: false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts.{Scope, Workspace, WorkspaceMembership}
  alias Fizz.Collaboration.EditSession.Supervisor
  alias Fizz.Repo
  alias Fizz.Workflows

  test "ensure_session creates a draft when one does not exist" do
    user = user_fixture()
    workspace = workspace_fixture!(user)
    scope = scoped_workspace_access(user, workspace)

    {:ok, workflow} =
      Workflows.create_workflow(scope, %{
        name: "Draftless #{System.unique_integer([:positive])}",
        description: "Workflow without a draft row"
      })

    assert {:error, :not_found} = Workflows.get_draft(scope, workflow.id)

    assert {:ok, pid} = Supervisor.ensure_session(scope, workflow.id)
    assert {:ok, _draft} = Workflows.get_draft(scope, workflow.id)

    ref = Process.monitor(pid)
    assert :ok = Supervisor.stop_session(workflow.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  defp workspace_fixture!(user) do
    unique = System.unique_integer([:positive])

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        name: "Edit Session Workspace #{unique}",
        slug: "edit-session-workspace-#{unique}",
        workos_organization_id: "org_#{unique}"
      })
      |> Repo.insert!()

    %WorkspaceMembership{workspace_id: workspace.id, user_id: user.id}
    |> WorkspaceMembership.changeset(%{role: :admin})
    |> Repo.insert!()

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
