defmodule Fizz.Integrations.Fizz.Builtins.HttpRequest do
  @moduledoc """
  Placeholder HTTP request step.

  The current executor validates the configured URL and returns a stubbed
  success payload. It does not issue a real network request yet.
  """

  use Fizz.Integrations.StepDefinition,
    id: "http_request",
    name: "HTTP Request",
    category: "Integrations",
    description: "Validate a URL and return a placeholder HTTP response",
    icon: "hero-globe-alt",
    kind: :action,
    integration: "fizz"

  @behaviour Fizz.Workflows.StepExecutor

  alias Fizz.Fields

  @fields [
    Fields.string("url", label: "URL", required?: true)
  ]

  @impl true
  def execute(config, _input, _context) do
    url = Map.get(config, "url") || Map.get(config, :url)
    {:ok, %{"url" => url, "status" => 200, "body" => %{"ok" => true}}}
  end

  @impl true
  def validate_config(config) do
    url = Map.get(config, "url") || Map.get(config, :url)

    if is_binary(url) and url != "" do
      :ok
    else
      {:error, [url: "is required"]}
    end
  end
end
