defmodule Fizz.Workflows.WorkflowRunTest do
  use Fizz.DataCase, async: true

  alias Fizz.Workflows.WorkflowRun

  test "valid status transitions are accepted" do
    assert WorkflowRun.transition_status(build_run(:pending), :running).valid?
    assert WorkflowRun.transition_status(build_run(:running), :sleeping).valid?
    assert WorkflowRun.transition_status(build_run(:running), :completed).valid?
    assert WorkflowRun.transition_status(build_run(:sleeping), :passivated).valid?
    assert WorkflowRun.transition_status(build_run(:passivated), :running).valid?
    assert WorkflowRun.transition_status(build_run(:passivated), :cancelled).valid?
  end

  test "invalid transitions are rejected" do
    changeset = WorkflowRun.transition_status(build_run(:completed), :running)

    refute changeset.valid?
    assert "cannot transition from completed to running" in errors_on(changeset).status
  end

  test "terminal states reject all transitions" do
    for status <- [:completed, :failed, :cancelled, :continued] do
      changeset = WorkflowRun.transition_status(build_run(status), :running)
      refute changeset.valid?
      assert "cannot transition from #{status} to running" in errors_on(changeset).status
    end
  end

  defp build_run(status) do
    now = DateTime.utc_now()

    %WorkflowRun{
      id: Ecto.UUID.generate(),
      workflow_definition_id: Ecto.UUID.generate(),
      workflow_definition_version_id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      workos_organization_id: "org_test",
      status: status,
      input: %{},
      last_active_at: now,
      started_at: now
    }
  end
end
