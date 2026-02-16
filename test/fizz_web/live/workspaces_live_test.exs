defmodule FizzWeb.WorkspacesLiveTest do
  use FizzWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "workspaces index requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/workspaces")
  end

  test "workspace show requires authentication", %{conn: conn} do
    workspace_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/workspaces/#{workspace_id}")
  end
end
