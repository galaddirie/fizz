defmodule Fizz.Steps.Executors.GitHubCreateIssue do
  @moduledoc """
  Creates a new GitHub issue.
  """

  use Fizz.Steps.Definition,
    id: "github_create_issue",
    name: "GitHub — Create Issue",
    category: "Development",
    description: "Open a new issue in a GitHub repository",
    icon: "/images/github.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.GitHubOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(GitHubOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      requirement_key: "auth"
                    )

  @default_config %{
    "credential_ref" => Fields.default_value(@credential_field)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["repository", "title"],
    "properties" => %{
      "credential_ref" =>
        Fields.to_schema_property(@credential_field,
          label: "GitHub Account",
          description: "GitHub account. Bound at run time per user."
        ),
      "repository" => %{
        "type" => "string",
        "title" => "Repository",
        "description" => "owner/repo format"
      },
      "title" => %{
        "type" => "string",
        "title" => "Issue Title"
      },
      "body" => %{
        "type" => "string",
        "title" => "Issue Body (Markdown)"
      },
      "labels" => %{
        "type" => "string",
        "title" => "Labels",
        "description" => "Comma-separated label names"
      },
      "assignees" => %{
        "type" => "string",
        "title" => "Assignees",
        "description" => "Comma-separated GitHub usernames"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "issue_number" => %{"type" => "integer"},
      "url" => %{"type" => "string"},
      "state" => %{"type" => "string"}
    }
  }

  @impl true
  def default_config, do: @default_config

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement GitHub REST issues.create
    {:ok, %{}}
  end
end
