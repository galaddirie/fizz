defmodule Fizz.Steps.Executors.GitHubCreatePR do
  @moduledoc """
  Opens a pull request on GitHub.
  """

  use Fizz.Steps.Definition,
    id: "github_create_pr",
    name: "GitHub — Create Pull Request",
    category: "Development",
    description: "Open a new pull request in a GitHub repository",
    icon: "/images/github.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "required" => ["repository", "title", "head", "base"],
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "GitHub Account"
      },
      "repository" => %{
        "type" => "string",
        "title" => "Repository"
      },
      "title" => %{
        "type" => "string",
        "title" => "PR Title"
      },
      "body" => %{
        "type" => "string",
        "title" => "PR Description (Markdown)"
      },
      "head" => %{
        "type" => "string",
        "title" => "Head Branch",
        "description" => "Branch with changes"
      },
      "base" => %{
        "type" => "string",
        "title" => "Base Branch",
        "default" => "main"
      },
      "draft" => %{
        "type" => "boolean",
        "title" => "Open as Draft",
        "default" => false
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "pr_number" => %{"type" => "integer"},
      "url" => %{"type" => "string"},
      "state" => %{"type" => "string"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement GitHub REST pulls.create
    {:ok, %{}}
  end
end
