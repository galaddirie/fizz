defmodule FizzWeb.WorkOSWebhookControllerTest do
  use FizzWeb.ConnCase, async: false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts

  setup do
    previous_secret = Application.get_env(:fizz, :workos_webhook_secret)
    Application.put_env(:fizz, :workos_webhook_secret, "whsec_test_123")

    on_exit(fn ->
      if previous_secret do
        Application.put_env(:fizz, :workos_webhook_secret, previous_secret)
      else
        Application.delete_env(:fizz, :workos_webhook_secret)
      end
    end)

    :ok
  end

  test "POST /webhooks/workos returns bad request when signature header is missing", %{conn: conn} do
    payload =
      webhook_payload("session.created", %{"id" => "session_123", "user_id" => "user_123"})

    body = Jason.encode!(payload)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/workos", body)

    assert conn.status == 400
    assert response(conn, 400) == "missing_workos_signature"
  end

  test "POST /webhooks/workos returns bad request for invalid signature", %{conn: conn} do
    payload =
      webhook_payload("session.created", %{"id" => "session_123", "user_id" => "user_123"})

    body = Jason.encode!(payload)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("workos-signature", signature_header(body, "wrong_secret"))
      |> post(~p"/webhooks/workos", body)

    assert conn.status == 400
    assert response(conn, 400) == "invalid_workos_signature"
  end

  test "POST /webhooks/workos returns error when webhook secret is missing", %{conn: conn} do
    Application.delete_env(:fizz, :workos_webhook_secret)

    body =
      webhook_payload("session.created", %{"id" => "session_123", "user_id" => "user_123"})
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("workos-signature", signature_header(body))
      |> post(~p"/webhooks/workos", body)

    assert conn.status == 500
    assert response(conn, 500) == "workos_webhook_secret_not_configured"
  end

  test "POST /webhooks/workos handles session.created", %{conn: conn} do
    body =
      webhook_payload("session.created", %{
        "id" => "session_created_123",
        "user_id" => "user_workos_session_created"
      })
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("workos-signature", signature_header(body))
      |> post(~p"/webhooks/workos", body)

    assert response(conn, 200) == ""
  end

  test "POST /webhooks/workos handles session.revoked by disconnecting local sockets", %{
    conn: conn
  } do
    topic = "workos_sessions:#{Base.url_encode64("session_revoked_123", padding: false)}"
    FizzWeb.Endpoint.subscribe(topic)
    user_fixture(%{workos_user_id: "user_workos_session_revoke"})

    body =
      webhook_payload("session.revoked", %{
        "id" => "session_revoked_123",
        "user_id" => "user_workos_session_revoke"
      })
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("workos-signature", signature_header(body))
      |> post(~p"/webhooks/workos", body)

    assert response(conn, 200) == ""
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
  end

  test "POST /webhooks/workos handles user.created", %{conn: conn} do
    body =
      webhook_payload("user.created", %{
        "id" => "user_workos_webhook_created",
        "email" => "created-via-webhook@example.com",
        "email_verified" => true
      })
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("workos-signature", signature_header(body))
      |> post(~p"/webhooks/workos", body)

    assert response(conn, 200) == ""
    assert user = Accounts.get_user_by_workos_user_id("user_workos_webhook_created")
    assert user.email == "created-via-webhook@example.com"
    assert user.confirmed_at
  end

  test "POST /webhooks/workos handles user.updated", %{conn: conn} do
    user_fixture(%{
      workos_user_id: "user_workos_webhook_updated",
      email: "before-updated@example.com",
      confirmed_at: nil
    })

    body =
      webhook_payload("user.updated", %{
        "id" => "user_workos_webhook_updated",
        "email" => "after-updated@example.com",
        "email_verified" => true
      })
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("workos-signature", signature_header(body))
      |> post(~p"/webhooks/workos", body)

    assert response(conn, 200) == ""
    assert user = Accounts.get_user_by_workos_user_id("user_workos_webhook_updated")
    assert user.email == "after-updated@example.com"
    assert user.confirmed_at
  end

  test "POST /webhooks/workos handles user.deleted", %{conn: conn} do
    user_fixture(%{workos_user_id: "user_workos_webhook_deleted"})

    body =
      webhook_payload("user.deleted", %{
        "id" => "user_workos_webhook_deleted"
      })
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("workos-signature", signature_header(body))
      |> post(~p"/webhooks/workos", body)

    assert response(conn, 200) == ""
    refute Accounts.get_user_by_workos_user_id("user_workos_webhook_deleted")
  end

  defp webhook_payload(event, data) do
    %{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "event" => event,
      "data" => data
    }
  end

  defp signature_header(payload, secret \\ "whsec_test_123") do
    timestamp = System.os_time(:millisecond)

    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end
end
