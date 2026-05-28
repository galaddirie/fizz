defmodule Fizz.Workflows.LeaseManagerTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Workflows.LeaseManager

  setup do
    manager_a = unique_name(:manager_a)
    manager_b = unique_name(:manager_b)
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope)

    start_supervised!({LeaseManager, name: manager_a, owner_node: "node-a", repo: Repo})
    start_supervised!({LeaseManager, name: manager_b, owner_node: "node-b", repo: Repo})

    %{manager_a: manager_a, manager_b: manager_b, scope: scope, version: version}
  end

  test "acquire lease returns an incremented fence token", %{
    manager_a: manager_a,
    scope: scope,
    version: version
  } do
    run_id = workflow_run_fixture(scope, version).id
    insert_lease(run_id, "old-node", 0, "NOW() - interval '1 second'")

    assert {:ok, 1} = LeaseManager.acquire(run_id, server: manager_a)
    assert %{owner_node: "node-a", fence_token: 1} = lease_row(run_id)
  end

  test "renewal extends lease expiry", %{
    manager_a: manager_a,
    scope: scope,
    version: version
  } do
    run_id = workflow_run_fixture(scope, version).id
    insert_lease(run_id, "old-node", 0, "NOW() - interval '1 second'")

    assert {:ok, 1} = LeaseManager.acquire(run_id, server: manager_a)

    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               UPDATE workflow_run_leases
               SET lease_expiry = NOW() + interval '1 second'
               WHERE run_id = $1
               """,
               [dump_uuid(run_id)]
             )

    old_expiry = lease_row(run_id).lease_expiry

    assert {:ok, [^run_id]} = LeaseManager.renew(server: manager_a)

    renewed_expiry = lease_row(run_id).lease_expiry
    assert NaiveDateTime.compare(renewed_expiry, old_expiry) == :gt
  end

  test "expired lease can be claimed by another node", %{
    manager_a: manager_a,
    manager_b: manager_b,
    scope: scope,
    version: version
  } do
    run_id = workflow_run_fixture(scope, version).id
    insert_lease(run_id, "old-node", 0, "NOW() - interval '1 second'")

    assert {:ok, 1} = LeaseManager.acquire(run_id, server: manager_a)

    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               UPDATE workflow_run_leases
               SET lease_expiry = NOW() - interval '1 second'
               WHERE run_id = $1
               """,
               [dump_uuid(run_id)]
             )

    assert {:ok, 2} = LeaseManager.acquire(run_id, server: manager_b)
    assert %{owner_node: "node-b", fence_token: 2} = lease_row(run_id)
  end

  test "concurrent acquisition allows only one winner", %{
    manager_a: manager_a,
    manager_b: manager_b,
    scope: scope,
    version: version
  } do
    run_id = workflow_run_fixture(scope, version).id
    insert_lease(run_id, "old-node", 0, "NOW() - interval '1 second'")

    task_a =
      Task.async(fn ->
        receive do
          :go -> LeaseManager.acquire(run_id, server: manager_a)
        end
      end)

    task_b =
      Task.async(fn ->
        receive do
          :go -> LeaseManager.acquire(run_id, server: manager_b)
        end
      end)

    send(task_a.pid, :go)
    send(task_b.pid, :go)

    results = [Task.await(task_a), Task.await(task_b)]

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :lease_unavailable}, &1)) == 1
  end

  defp insert_lease(run_id, owner_node, fence_token, lease_expiry_sql) do
    assert {:ok, _result} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO workflow_run_leases (run_id, owner_node, fence_token, checkpoint_seq, lease_expiry)
               VALUES ($1, $2, $3, 0, #{lease_expiry_sql})
               """,
               [dump_uuid(run_id), owner_node, fence_token]
             )
  end

  defp lease_row(run_id) do
    assert {:ok, %{rows: [[owner_node, fence_token, lease_expiry]]}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               SELECT owner_node, fence_token, lease_expiry
               FROM workflow_run_leases
               WHERE run_id = $1
               """,
               [dump_uuid(run_id)]
             )

    %{owner_node: owner_node, fence_token: fence_token, lease_expiry: lease_expiry}
  end

  defp unique_name(name) do
    Module.concat([__MODULE__, "#{name}_#{System.unique_integer([:positive])}"])
  end

  defp dump_uuid(run_id), do: Ecto.UUID.dump!(run_id)
end
