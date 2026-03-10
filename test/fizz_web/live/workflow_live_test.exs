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
end
