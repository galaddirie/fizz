defmodule FizzWeb.SpritesLiveTest do
  use FizzWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "sprites index requires authentication", %{conn: conn} do
    project_id = Ecto.UUID.generate()

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/projects/#{project_id}/sprites")
  end
end
