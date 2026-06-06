defmodule FizzWeb.Triggers.WebhookController do
  use FizzWeb, :controller

  alias Fizz.Triggers
  alias Fizz.Triggers.Registry
  alias Fizz.Triggers.Webhook
  alias Fizz.Triggers.Workers.TriggerFireWorker

  def receive(conn, %{"webhook_path" => path}) do
    with {:ok, registration} <- fetch_registration(path),
         {:ok, raw_body} <- fetch_raw_body(conn),
         {:ok, raw_event} <- decode_event(raw_body),
         {:ok, signature} <- fetch_signature(conn, registration.registration_params),
         true <-
           Webhook.verify_signature(
             raw_body,
             registration.webhook_secret,
             signature,
             signature_algorithm(registration.registration_params)
           ),
         {:ok, executor} <- Triggers.resolve_registration_executor(registration) do
      enriched_event = enrich_event(conn, raw_event)

      case executor.match?(registration.registration_params, enriched_event) do
        true ->
          case executor.normalize_event(registration.registration_params, enriched_event) do
            {:ok, normalized_data} ->
              case enqueue_trigger_fire(
                     registration.id,
                     webhook_event_id(conn, raw_body),
                     normalized_data
                   ) do
                {:ok, _job} -> send_resp(conn, :accepted, "")
                {:error, _reason} -> send_resp(conn, :unprocessable_entity, "")
              end

            {:error, _reason} ->
              send_resp(conn, :unprocessable_entity, "")
          end

        false ->
          send_resp(conn, :ok, "")
      end
    else
      :error ->
        send_resp(conn, :not_found, "")

      {:error, :missing_raw_body} ->
        send_resp(conn, :unprocessable_entity, "")

      {:error, :invalid_json} ->
        send_resp(conn, :unprocessable_entity, "")

      {:error, :missing_signature} ->
        send_resp(conn, :unauthorized, "")

      false ->
        send_resp(conn, :unauthorized, "")

      {:error, _reason} ->
        send_resp(conn, :unprocessable_entity, "")
    end
  end

  defp fetch_registration(path) do
    Registry.get_by_webhook_path(path)
  end

  defp fetch_raw_body(conn) do
    case conn.private[:raw_body] do
      body when is_binary(body) and byte_size(body) > 0 -> {:ok, body}
      _ -> {:error, :missing_raw_body}
    end
  end

  defp decode_event(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp fetch_signature(conn, params) do
    header_names =
      params
      |> Map.get("signature_header")
      |> List.wrap()
      |> Enum.map(&String.downcase/1)
      |> Enum.concat(["x-hub-signature-256", "x-fizz-signature", "x-signature"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case Enum.find_value(header_names, fn header_name ->
           case get_req_header(conn, header_name) do
             [value | _rest] when is_binary(value) and value != "" -> value
             _ -> nil
           end
         end) do
      nil -> {:error, :missing_signature}
      signature -> {:ok, signature}
    end
  end

  defp signature_algorithm(params) do
    Map.get(params, "signature_algorithm", "hmac-sha256")
  end

  defp enrich_event(conn, raw_event) do
    %{
      "body" => raw_event,
      "headers" => request_headers(conn),
      "method" => conn.method,
      "path" => conn.request_path,
      "query_params" => conn.query_params
    }
  end

  defp request_headers(conn) do
    conn.req_headers
    |> Enum.reduce(%{}, fn {key, value}, acc -> Map.put(acc, String.downcase(key), value) end)
  end

  defp webhook_event_id(conn, raw_body) do
    case Enum.find_value(["x-github-delivery", "x-event-id", "x-request-id"], fn header_name ->
           case get_req_header(conn, header_name) do
             [value | _rest] when is_binary(value) and value != "" -> value
             _ -> nil
           end
         end) do
      nil ->
        :crypto.hash(:sha256, raw_body)
        |> Base.encode16(case: :lower)

      event_id ->
        event_id
    end
  end

  defp enqueue_trigger_fire(trigger_registration_id, event_id, normalized_data) do
    %{
      "trigger_registration_id" => trigger_registration_id,
      "event_id" => event_id,
      "normalized_data" => normalized_data
    }
    |> TriggerFireWorker.new()
    |> Oban.insert()
  end
end
