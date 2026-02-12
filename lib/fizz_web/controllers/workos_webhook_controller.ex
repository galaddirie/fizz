defmodule FizzWeb.WorkOSWebhookController do
  use FizzWeb, :controller

  require Logger

  alias Fizz.Accounts.WorkOSWebhooks

  def create(conn, _params) do
    with {:ok, webhook_secret} <- webhook_secret(),
         {:ok, signature} <- signature(conn),
         {:ok, payload} <- payload(conn),
         {:ok, event} <- construct_event(payload, signature, webhook_secret),
         :ok <- WorkOSWebhooks.handle_event(event) do
      send_resp(conn, :ok, "")
    else
      {:error, :missing_webhook_secret} ->
        send_resp(conn, :internal_server_error, "workos_webhook_secret_not_configured")

      {:error, :missing_signature} ->
        send_resp(conn, :bad_request, "missing_workos_signature")

      {:error, :missing_payload} ->
        send_resp(conn, :bad_request, "missing_webhook_payload")

      {:error, :invalid_signature} ->
        send_resp(conn, :bad_request, "invalid_workos_signature")

      {:error, reason} ->
        Logger.error("WorkOS webhook handling failed: #{inspect(reason)}")
        send_resp(conn, :internal_server_error, "workos_webhook_processing_failed")
    end
  end

  defp webhook_secret do
    case Application.get_env(:fizz, :workos_webhook_secret) ||
           Application.get_env(:workos, :webhook_signing_secret) do
      secret when is_binary(secret) and byte_size(secret) > 0 ->
        {:ok, secret}

      _ ->
        {:error, :missing_webhook_secret}
    end
  end

  defp signature(conn) do
    case get_req_header(conn, "workos-signature") do
      [signature | _rest] when is_binary(signature) and byte_size(signature) > 0 ->
        {:ok, signature}

      _ ->
        {:error, :missing_signature}
    end
  end

  defp payload(conn) do
    case conn.private[:raw_body] do
      payload when is_binary(payload) and byte_size(payload) > 0 ->
        {:ok, payload}

      _ ->
        {:error, :missing_payload}
    end
  end

  defp construct_event(payload, signature, secret) do
    case WorkOS.Webhooks.construct_event(payload, signature, secret) do
      {:ok, event} -> {:ok, event}
      {:error, _message} -> {:error, :invalid_signature}
    end
  end
end
