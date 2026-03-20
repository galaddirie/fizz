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
  alias Fizz.Triggers.RegistrationSpec

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
      "events" => %{
        "type" => "array",
        "title" => "Events",
        "items" => %{
          "type" => "string",
          "enum" => ["push", "pull_request", "issues", "release", "workflow_run"]
        },
        "default" => ["push"]
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "event_type" => %{"type" => "string"},
      "action" => %{"type" => "string"},
      "repository" => %{"type" => "string"},
      "sender" => %{"type" => "string"},
      "ref" => %{"type" => "string", "description" => "Branch ref for push events"},
      "delivery_id" => %{"type" => "string"},
      "payload" => %{"type" => "object", "description" => "Full GitHub webhook payload"}
    }
  }

  @impl true
  def registration_spec(config, _context) do
    {:ok,
     %RegistrationSpec{
       kind: :webhook,
       params: %{
         "events" => configured_events(config),
         "repository" => Map.get(config, "repository")
       }
     }}
  end

  @impl true
  def match?(config, incoming_event) do
    configured_events = configured_events(config)
    repository = Map.get(config, "repository")
    event_type = get_in(incoming_event, ["headers", "x-github-event"])
    incoming_repository = get_in(incoming_event, ["body", "repository", "full_name"])

    events_match? =
      case configured_events do
        [] -> true
        values -> event_type in values
      end

    repository_match? =
      case repository do
        nil -> true
        "" -> true
        value -> value == incoming_repository
      end

    events_match? and repository_match?
  end

  @impl true
  def normalize_event(_config, raw_event) do
    payload = Map.get(raw_event, "body", raw_event)

    {:ok,
     %{
       "event_type" => get_in(raw_event, ["headers", "x-github-event"]),
       "action" => Map.get(payload, "action"),
       "repository" => get_in(payload, ["repository", "full_name"]),
       "sender" => get_in(payload, ["sender", "login"]),
       "ref" => Map.get(payload, "ref"),
       "delivery_id" => get_in(raw_event, ["headers", "x-github-delivery"]),
       "payload" => payload
     }}
  end

  @impl true
  def execute(_config, input, _ctx) do
    {:ok, input}
  end

  defp configured_events(config) do
    case Map.get(config, "events") do
      values when is_list(values) ->
        values

      nil ->
        case Map.get(config, "event_type") do
          value when is_binary(value) -> [value]
          _ -> []
        end

      _ ->
        []
    end
  end
end
