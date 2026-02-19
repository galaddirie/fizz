defmodule FizzWeb.WorkflowLiveTest do
  use FizzWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "workflow index requires authentication", %{conn: conn} do
    workspace_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/workspaces/#{workspace_id}/workflows")
  end

  test "workflow show requires authentication", %{conn: conn} do
    workspace_id = Ecto.UUID.generate()
    workflow_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}")
  end

  test "workflow edit requires authentication", %{conn: conn} do
    workspace_id = Ecto.UUID.generate()
    workflow_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}/edit")
  end

  test "workflow revisions requires authentication", %{conn: conn} do
    workspace_id = Ecto.UUID.generate()
    workflow_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}/revisions")
  end

  test "execution show requires authentication", %{conn: conn} do
    workspace_id = Ecto.UUID.generate()
    workflow_id = Ecto.UUID.generate()
    execution_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(
               conn,
               ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}/execution/#{execution_id}"
             )
  end
end
