defmodule Fizz.Integrations.Library.GitHub.Actions.CreatePullRequest do
  @moduledoc """
  Opens a pull request on GitHub.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "github_create_pr",
    name: "GitHub — Create Pull Request",
    category: "Development",
    description: "Open a new pull request in a GitHub repository",
    icon: "/images/github.svg",
    kind: :action,
    provider: "github_oauth",
    integration: "github"

  use Fizz.Integrations.Steps.Placeholder

  alias Fizz.Integrations.Auth.Providers.GitHubOAuth
  alias Fizz.Fields

  @credential_field Fields.credential(GitHubOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "GitHub Account",
                      description: "GitHub account. Bound at run time per user.",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("repository", label: "Repository", required?: true),
    Fields.string("title", label: "PR Title", required?: true),
    Fields.string("body", label: "PR Description (Markdown)"),
    Fields.string("head",
      label: "Head Branch",
      required?: true,
      description: "Branch with changes"
    ),
    Fields.string("base", label: "Base Branch", required?: true, default: "main"),
    Fields.boolean("draft", label: "Open as Draft", default: false)
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "pr_number" => %{"type" => "integer"},
      "url" => %{"type" => "string"},
      "state" => %{"type" => "string"}
    }
  }
end
