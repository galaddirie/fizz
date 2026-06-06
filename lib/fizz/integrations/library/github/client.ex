defmodule Fizz.Integrations.Library.GitHub.Client do
  @moduledoc """
  GitHub API client for GitHub library integrations.
  """

  alias Fizz.Accounts.Scope
  alias Fizz.Integrations.Auth.Providers.GitHubOAuth

  @spec list_repos(Scope.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_repos(%Scope{} = scope, opts) when is_list(opts) do
    organization_id = Keyword.get(opts, :organization_id)

    with {:ok, token_result} <- GitHubOAuth.fetch_token(scope, organization_id) do
      per_page = Keyword.get(opts, :per_page, 30)
      page = Keyword.get(opts, :page, 1)
      sort = Keyword.get(opts, :sort, "updated")

      case get(token_result.access_token, "/user/repos",
             per_page: per_page,
             page: page,
             sort: sort
           ) do
        {:ok, repos} -> {:ok, Enum.map(repos, &repo_metadata/1)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create_pull_request(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_pull_request(%Scope{} = scope, params) when is_map(params) do
    organization_id = Map.get(params, "organization_id") || Map.get(params, :organization_id)

    with {:ok, token_result} <- GitHubOAuth.fetch_token(scope, organization_id) do
      owner = Map.fetch!(params, "owner")
      repo = Map.fetch!(params, "repo")

      body = %{
        title: Map.fetch!(params, "title"),
        head: Map.fetch!(params, "head"),
        base: Map.fetch!(params, "base"),
        body: Map.get(params, "body", "")
      }

      post(token_result.access_token, "/repos/#{owner}/#{repo}/pulls", body)
    end
  end

  @spec get_user(String.t()) :: {:ok, map()} | {:error, term()}
  def get_user(token) when is_binary(token), do: get(token, "/user")

  defp repo_metadata(repo) do
    %{
      id: repo["id"],
      name: repo["name"],
      full_name: repo["full_name"],
      description: repo["description"],
      private: repo["private"],
      html_url: repo["html_url"],
      clone_url: repo["clone_url"],
      default_branch: repo["default_branch"],
      updated_at: repo["updated_at"]
    }
  end

  defp get(token, path, params \\ []) do
    case Req.get(
           url: "https://api.github.com#{path}",
           headers: headers(token),
           params: params
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :forbidden}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(token, path, body) do
    case Req.post(
           url: "https://api.github.com#{path}",
           headers: headers(token),
           json: body
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 422, body: body}} ->
        {:error, {:validation_failed, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]
  end
end
