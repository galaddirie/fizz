defmodule Fizz.Steps.Executors.WebhookTrigger do
  @moduledoc """
  Trigger node that outputs incoming webhook data.

  ## Configuration

  - `path_label` (optional) - A descriptive name for this webhook endpoint.
  - `auth_token` (optional) - Required token to authorize requests.

  ## Output

  The full webhook payload including body, params, and headers.
  """
  use Fizz.Steps.Definition,
    id: "webhook_trigger",
    name: "Webhook Trigger",
    category: "Triggers",
    description: "Accepts incoming HTTP requests to start the workflow",
    icon: "hero-bolt",
    kind: :trigger

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{
        "type" => "string",
        "title" => "Webhook Path",
        "description" => "Custom slug for the webhook endpoint"
      },
      "http_method" => %{
        "type" => "string",
        "title" => "HTTP Method",
        "enum" => ["GET", "POST", "PUT", "PATCH", "DELETE", "ANY"],
        "default" => "POST"
      },
      "body_schema" => %{
        "type" => "object",
        "title" => "Request Body Schema",
        "description" => "JSON Schema describing expected request body"
      },
      "params_schema" => %{
        "type" => "object",
        "title" => "Query Parameters Schema",
        "description" => "JSON Schema describing expected query params"
      },
      "validate_input" => %{
        "type" => "boolean",
        "title" => "Validate Input",
        "default" => false,
        "description" => "Reject requests that do not match declared schemas"
      },
      "response_mode" => %{
        "type" => "string",
        "title" => "Response Mode",
        "enum" => ["immediate", "on_completion", "on_respond_node"],
        "default" => "immediate"
      },
      "auth_token" => %{
        "type" => "string",
        "title" => "Auth Token",
        "description" => "Optional token to protect this webhook"
      }
    }
  }

  @impl true
  def default_config do
    %{
      "path" => Ecto.UUID.generate(),
      "http_method" => "POST",
      "response_mode" => "immediate",
      "validate_input" => false
    }
  end

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "body" => %{"type" => "object"},
      "headers" => %{"type" => "object"},
      "params" => %{"type" => "object"},
      "method" => %{"type" => "string"}
    }
  }

  @behaviour Fizz.Steps.Executors.Behaviour

  @impl true
  def execute(config, input, _context) do
    # For triggers, 'input' is the trigger payload provided by the runtime
    case validate_payload(input, config) do
      :ok -> {:ok, input}
      {:error, errors} -> {:error, {:validation_failed, errors}}
    end
  end

  @doc false
  def validate_payload(input, config) do
    if Map.get(config, "validate_input", false) do
      validate_against_schema(input, config)
    else
      :ok
    end
  end

  @impl true
  def effective_output_schema(config) do
    @output_schema
    |> maybe_put_schema("body", Map.get(config, "body_schema"))
    |> maybe_put_schema("params", Map.get(config, "params_schema"))
  end

  defp maybe_put_schema(schema, _key, nil), do: schema

  defp maybe_put_schema(schema, key, custom_schema) do
    update_in(schema, ["properties", key], fn _ -> custom_schema end)
  end

  defp validate_against_schema(input, config) do
    validations = [
      {"body", Map.get(input, "body"), Map.get(config, "body_schema")},
      {"params", Map.get(input, "params"), Map.get(config, "params_schema")}
    ]

    errors =
      Enum.reduce(validations, [], fn {field, value, schema}, acc ->
        case validate_field_schema(field, value, schema) do
          :ok -> acc
          {:error, error} -> [error | acc]
        end
      end)

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp validate_field_schema(_field, _value, nil), do: :ok

  defp validate_field_schema(field, value, schema) do
    case JSV.build(schema) do
      {:ok, compiled} ->
        case JSV.validate(value, compiled) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            {:error, %{field: field, errors: JSV.normalize_error(error)}}
        end

      {:error, error} ->
        {:error, %{field: field, errors: %{message: Exception.message(error)}}}
    end
  end
end
