defmodule Fizz.Executions.CancelActiveStepExecutionsTest do
  use Fizz.DataCase, async: false

  alias Fizz.Accounts.{Scope, Workspace, WorkspaceMembership}
  alias Fizz.Executions
  alias Fizz.Repo
  alias Fizz.Workflows

  setup do
    user = Fizz.AccountsFixtures.user_fixture()
    workspace = workspace_fixture!(user)
    scope = scoped_workspace_access(user, workspace)
    workflow = workflow_fixture!(scope)
    execution = execution_fixture!(scope, workflow)

    %{scope: scope, execution: execution}
  end

  test "broadcasts cancelled step events with per-item identity", %{
    scope: scope,
    execution: execution
  } do
    _step_zero =
      step_execution_fixture!(scope, execution, %{
        step_id: "fan_out_step",
        item_index: 0,
        items_total: 2
      })

    _step_one =
      step_execution_fixture!(scope, execution, %{
        step_id: "fan_out_step",
        item_index: 1,
        items_total: 2
      })

    :ok =
      Phoenix.PubSub.subscribe(Fizz.PubSub, Fizz.Executions.PubSub.execution_topic(execution.id))

    assert {2, nil} = Executions.cancel_active_step_executions(execution.id)

    payloads =
      Enum.map(1..2, fn _ ->
        assert_receive {:execution_event, %{event_name: :step_cancelled, payload: payload}}, 1_000
        payload
      end)

    assert Enum.sort(Enum.map(payloads, & &1["item_index"])) == [0, 1]
    assert Enum.all?(payloads, &(&1["status"] == "cancelled"))
    assert Enum.all?(payloads, &(&1["attempt"] == 1))
    assert Enum.all?(payloads, &(&1["step_id"] == "fan_out_step"))
  end

  defp workspace_fixture!(user) do
    unique = System.unique_integer([:positive])

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        name: "Execution Cancel Workspace #{unique}",
        slug: "execution-cancel-workspace-#{unique}",
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

  defp workflow_fixture!(scope) do
    {:ok, workflow} =
      Workflows.create_workflow(scope, %{
        name: "Cancel Broadcast Workflow #{System.unique_integer([:positive])}",
        description: "cancel broadcast regression"
      })

    workflow
  end

  defp execution_fixture!(scope, workflow) do
    {:ok, execution} =
      Executions.create_execution(scope, %{
        workflow_id: workflow.id,
        status: :running,
        execution_type: :preview,
        started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        trigger: %{
          type: :manual,
          data: %{"source" => "test"}
        }
      })

    execution
  end

  defp step_execution_fixture!(scope, execution, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, step_execution} =
      Executions.create_step_execution(
        scope,
        Map.merge(
          %{
            execution_id: execution.id,
            step_id: "step_a",
            step_type_id: "math",
            status: :running,
            attempt: 1,
            started_at: now
          },
          attrs
        )
      )

    step_execution
  end
end
