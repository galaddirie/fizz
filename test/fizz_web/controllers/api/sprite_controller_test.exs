defmodule FizzWeb.Api.SpriteControllerTest do
  use FizzWeb.ConnCase, async: true

  import Fizz.AccountsFixtures

  test "GET /api/v1/workspaces/:workspace_id/sprites requires authentication", %{conn: conn} do
    workspace_id = Ecto.UUID.generate()

    conn = get(conn, ~p"/api/v1/workspaces/#{workspace_id}/sprites")

    assert json_response(conn, 401) == %{"error" => "unauthenticated"}
  end

  test "GET /api/v1/workspaces/:workspace_id/sprites returns not found for missing workspace", %{
    conn: conn
  } do
    user = user_fixture()
    conn = log_in_user(conn, user)

    workspace_id = Ecto.UUID.generate()
    conn = get(conn, ~p"/api/v1/workspaces/#{workspace_id}/sprites")

    assert json_response(conn, 404) == %{"error" => "workspace_not_found"}
  end
end
