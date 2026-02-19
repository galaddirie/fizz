defmodule Fizz.Steps.Executors.HttpRequest do
  use Fizz.Steps.Definition,
    id: "http_request",
    name: "HTTP Request",
    category: "Integrations",
    description: "Fetch data from a URL",
    icon: "hero-globe-alt",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "required" => ["url"],
    "properties" => %{
      "url" => %{"type" => "string", "title" => "URL"}
    }
  }

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
