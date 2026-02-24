defmodule Fizz.Steps.Executors.GitHubTrigger do
  @moduledoc """
  Trigger that fires on GitHub repository events (push, PR, issue, etc.).
  """

  use Fizz.Steps.Definition,
    id: "github_trigger",
    name: "GitHub — Repository Event",
    category: "Triggers",
    description: "Fires on GitHub events: push, pull request, issue, release, etc.",
    icon: "/images/github.svg",
    kind: :trigger

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "GitHub Account"
      },
      "repository" => %{
        "type" => "string",
        "title" => "Repository",
        "description" => "owner/repo format (e.g. acme/website)"
      },
      "event_type" => %{
        "type" => "string",
        "title" => "Event Type",
        "enum" => ["push", "pull_request", "issues", "release", "workflow_run"],
        "default" => "push"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "event_type" => %{"type" => "string"},
      "repository" => %{"type" => "string"},
      "sender" => %{"type" => "string"},
      "ref" => %{"type" => "string", "description" => "Branch ref for push events"},
      "payload" => %{"type" => "object", "description" => "Full GitHub webhook payload"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement GitHub webhook receiver / polling
    {:ok, %{}}
  end
end
