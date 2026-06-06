defmodule Fizz.Integrations.Library.GitHub do
  @moduledoc """
  GitHub product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "github",
    display_name: "GitHub",
    provider_id: "github_oauth",
    actions: ["github_create_issue", "github_create_pr"],
    step_modules: [
      Fizz.Integrations.Library.GitHub.Triggers.RepositoryEvent,
      Fizz.Integrations.Library.GitHub.Actions.CreateIssue,
      Fizz.Integrations.Library.GitHub.Actions.CreatePullRequest
    ]
end
