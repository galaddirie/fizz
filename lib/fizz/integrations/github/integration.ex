defmodule Fizz.Integrations.GitHub do
  @moduledoc """
  GitHub product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "github",
    display_name: "GitHub",
    provider_id: "github_oauth",
    actions: ["github_create_issue", "github_create_pr"],
    step_modules: [
      Fizz.Integrations.GitHub.Triggers.RepositoryEvent,
      Fizz.Integrations.GitHub.Actions.CreateIssue,
      Fizz.Integrations.GitHub.Actions.CreatePullRequest
    ]
end
