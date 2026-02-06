defmodule FizzWeb.PageController do
  use FizzWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
