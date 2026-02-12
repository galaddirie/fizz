defmodule Fizz.Steps.Executors.RespondToWebhook do
  @moduledoc """
  Node that sends a response back to the webhook caller.

  This is used when the Webhook Trigger is set to `on_respond_node`.
  """
  use Fizz.Steps.Definition,
    id: "respond_to_webhook",
    name: "Respond to Webhook",
    category: "Communication",
    description: "Sends a response back to the incoming webhook request",
    icon: "hero-reply",
    kind: :action

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "status" => %{
        "type" => "integer",
        "title" => "Status Code",
        "default" => 200
      },
      "body" => %{
        "type" => "string",
        "title" => "Response Body",
        "description" => "The data to return (can be an expression)"
      },
      "content_type" => %{
        "type" => "string",
        "title" => "Content Type",
        "default" => "application/json"
      }
    }
  }

  @behaviour Fizz.Steps.Executors.Behaviour

  @impl true
  def execute(config, input, context) do
    # 1. Resolve body expression if it's dynamic
    body = Map.get(config, "body", input)
    status = Map.get(config, "status", 200)
    content_type = Map.get(config, "content_type", "application/json")

    # 2. Extract handler PID from context metadata
    # We'll need to ensure the runtime passes this along
    case get_handler_pid(context) do
      pid when is_pid(pid) ->
        send(pid, {:webhook_response, %{status: status, body: body, content_type: content_type}})
        {:ok, input}

      nil ->
        # Log warning if no handler found, but continue (maybe it's a test or async run)
        {:ok, input}
    end
  end

  defp get_handler_pid(context) do
    Map.get(context.metadata, :webhook_handler_pid) ||
      Map.get(context.metadata, "webhook_handler_pid")
  end
end
