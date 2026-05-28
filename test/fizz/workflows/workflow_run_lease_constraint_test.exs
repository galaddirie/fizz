defmodule Fizz.Workflows.WorkflowRunLeaseConstraintTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  test "workflow run leases require an existing workflow run" do
    orphan_run_id = Ecto.UUID.generate()

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             insert_lease(orphan_run_id)
  end

  test "deleting a workflow run cascades to its lease" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope)
    run = workflow_run_fixture(scope, version)

    assert {:ok, _result} = insert_lease(run.id)
    assert lease_exists?(run.id)

    Repo.delete!(run)

    refute lease_exists?(run.id)
  end

  defp insert_lease(run_id) do
    Ecto.Adapters.SQL.query(
      Repo,
      """
      INSERT INTO workflow_run_leases (run_id, owner_node, fence_token, checkpoint_seq, lease_expiry)
      VALUES ($1, NULL, 1, 0, NOW() + interval '30 seconds')
      """,
      [dump_uuid(run_id)]
    )
  end

  defp lease_exists?(run_id) do
    assert {:ok, %{rows: [[count]]}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "SELECT COUNT(*) FROM workflow_run_leases WHERE run_id = $1",
               [dump_uuid(run_id)]
             )

    count == 1
  end

  defp dump_uuid(run_id), do: Ecto.UUID.dump!(run_id)
end
