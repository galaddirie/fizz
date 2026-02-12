defmodule FizzWeb.PageControllerTest do
  use FizzWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "End-to-end reactivity for your Live Vue apps."
  end
end
