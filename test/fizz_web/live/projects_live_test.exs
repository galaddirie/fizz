defmodule FizzWeb.ProjectsLiveTest do
  use FizzWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "projects index requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/projects")
  end

  test "project show requires authentication", %{conn: conn} do
    project_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/projects/#{project_id}")
  end
end
