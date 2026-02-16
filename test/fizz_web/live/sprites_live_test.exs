defmodule FizzWeb.SpritesLiveTest do
  use FizzWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "sprites index requires authentication", %{conn: conn} do
    workspace_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/workspaces/#{workspace_id}/sprites")
  end
end
