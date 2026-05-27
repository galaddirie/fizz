defmodule Fizz.Integrations.GitHub.Actions.CreateIssue do
  @moduledoc """
  Creates a new GitHub issue.
  """

  use Fizz.Integrations.StepDefinition,
    id: "github_create_issue",
    name: "GitHub — Create Issue",
    category: "Development",
    description: "Open a new issue in a GitHub repository",
    icon: "/images/github.svg",
    kind: :action,
    provider: "github_oauth",
    integration: "github"

  use Fizz.Integrations.PlaceholderStep

  alias Fizz.Integrations.Providers.GitHubOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(GitHubOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "GitHub Account",
                      description: "GitHub account. Bound at run time per user.",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("repository",
      label: "Repository",
      required?: true,
      description: "owner/repo format"
    ),
    Fields.string("title", label: "Issue Title", required?: true),
    Fields.string("body", label: "Issue Body (Markdown)"),
    Fields.string("labels", label: "Labels", description: "Comma-separated label names"),
    Fields.string("assignees",
      label: "Assignees",
      description: "Comma-separated GitHub usernames"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "issue_number" => %{"type" => "integer"},
      "url" => %{"type" => "string"},
      "state" => %{"type" => "string"}
    }
  }
end
