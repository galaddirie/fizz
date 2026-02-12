defmodule Fizz.Accounts.WorkOSWebhooks do
  @moduledoc """
  Handles supported WorkOS webhook events for session and user lifecycle sync.
  """

  require Logger

  alias Fizz.Accounts
  alias WorkOS.Webhooks.Event

  @spec handle_event(Event.t() | map()) :: :ok | {:error, term()}
  def handle_event(%Event{event: event, data: data}) do
    handle_event(event, data)
  end

  def handle_event(%{event: event, data: data}) do
    handle_event(event, data)
  end

  def handle_event(_event), do: {:error, :invalid_workos_event}

  defp handle_event("session.created", _data), do: :ok

  defp handle_event("session.revoked", data) do
    with workos_user_id when is_binary(workos_user_id) <- extract_workos_user_id(data) do
      Accounts.revoke_user_sessions_by_workos_user_id(workos_user_id)
    else
      _ -> {:error, :invalid_workos_session_payload}
    end
  end

  defp handle_event("user.created", data), do: upsert_user(data)
  defp handle_event("user.updated", data), do: upsert_user(data)

  defp handle_event("user.deleted", data) do
    with workos_user_id when is_binary(workos_user_id) <- extract_value(data, [:id, "id"]) do
      Accounts.delete_user_by_workos_user_id(workos_user_id)
    else
      _ -> {:error, :invalid_workos_user_payload}
    end
  end

  defp handle_event(event, _data) when is_binary(event) do
    Logger.debug("Ignoring unsupported WorkOS webhook event: #{event}")
    :ok
  end

  defp handle_event(_event, _data), do: {:error, :invalid_workos_event}

  defp upsert_user(data) do
    with workos_user_id when is_binary(workos_user_id) <- extract_value(data, [:id, "id"]),
         email when is_binary(email) <- extract_value(data, [:email, "email"]) do
      Accounts.upsert_user_from_workos_profile(%{
        id: workos_user_id,
        email: email,
        email_verified: extract_value(data, [:email_verified, "email_verified"]) in [true, "true"]
      })
      |> normalize_result()
    else
      _ -> {:error, :invalid_workos_user_payload}
    end
  end

  defp normalize_result({:ok, _user}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}

  defp extract_workos_user_id(data) do
    extract_value(data, [:user_id, "user_id"]) ||
      extract_value(data, [:userId, "userId"])
  end

  defp extract_value(data, keys) do
    Enum.find_value(keys, fn key ->
      case data do
        %{} -> Map.get(data, key)
        _ -> nil
      end
    end)
  end
end
