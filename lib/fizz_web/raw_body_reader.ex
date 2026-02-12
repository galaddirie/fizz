defmodule FizzWeb.RawBodyReader do
  @moduledoc false

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, append_raw_body(conn, body)}

      {:more, body, conn} ->
        {:more, body, append_raw_body(conn, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_raw_body(conn, body) do
    existing_body = conn.private[:raw_body] || ""
    Plug.Conn.put_private(conn, :raw_body, existing_body <> body)
  end
end
