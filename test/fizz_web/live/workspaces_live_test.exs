defmodule FizzWeb.WorkspacesLiveTest do
  use FizzWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "workspaces index requires authentication", %{conn: conn} do
    project_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/projects/#{project_id}/workspaces")
  end
end
