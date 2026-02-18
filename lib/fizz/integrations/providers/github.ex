defmodule Fizz.Integrations.Providers.GitHub do
  @moduledoc """
  GitHub integration provider. Uses WorkOS Pipes for OAuth token management.
  """

  @behaviour Fizz.Integrations.Provider

  alias Fizz.Accounts

  require Logger

  @impl true
  def provider_id, do: "github_oauth"

  @impl true
  def display_name, do: "GitHub"

  @impl true
  def check_connection(scope, organization_id) do
    case Accounts.get_pipes_access_token(scope, "github", organization_id) do
      {:ok, %{active: true} = result} ->
        {:ok,
         %{
           active: true,
           scopes: result[:scopes] || [],
           missing_scopes: result[:missing_scopes] || [],
           provider_metadata: fetch_user_metadata(result[:access_token]),
           error: nil
         }}

      {:ok, %{active: false, error: error}} ->
        {:ok,
         %{
           active: false,
           scopes: [],
           missing_scopes: [],
           provider_metadata: %{},
           error: error
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_token(scope, organization_id) do
    case Accounts.get_pipes_access_token(scope, "github", organization_id) do
      {:ok, %{active: true, access_token: token} = result} when is_binary(token) ->
        {:ok,
         %{
           access_token: token,
           expires_at: result[:expires_at],
           scopes: result[:scopes] || [],
           missing_scopes: result[:missing_scopes] || []
         }}

      {:ok, %{active: false, error: error}} ->
        {:error, {:provider_inactive, error}}

      {:ok, _} ->
        {:error, :no_access_token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def network_domains do
    ["github.com", "api.github.com", "*.githubusercontent.com"]
  end

  @impl true
  def list_repos(scope, opts) do
    organization_id = Keyword.get(opts, :organization_id)

    with {:ok, token_result} <- fetch_token(scope, organization_id) do
      per_page = Keyword.get(opts, :per_page, 30)
      page = Keyword.get(opts, :page, 1)
      sort = Keyword.get(opts, :sort, "updated")

      case github_api_get(token_result.access_token, "/user/repos",
             per_page: per_page,
             page: page,
             sort: sort
           ) do
        {:ok, repos} ->
          {:ok,
           Enum.map(repos, fn repo ->
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
           end)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def create_pull_request(scope, params) do
    organization_id = Map.get(params, "organization_id") || Map.get(params, :organization_id)

    with {:ok, token_result} <- fetch_token(scope, organization_id) do
      owner = Map.fetch!(params, "owner")
      repo = Map.fetch!(params, "repo")

      body = %{
        title: Map.fetch!(params, "title"),
        head: Map.fetch!(params, "head"),
        base: Map.fetch!(params, "base"),
        body: Map.get(params, "body", "")
      }

      github_api_post(token_result.access_token, "/repos/#{owner}/#{repo}/pulls", body)
    end
  end

  # Private helpers

  defp fetch_user_metadata(nil), do: %{}

  defp fetch_user_metadata(token) do
    case github_api_get(token, "/user") do
      {:ok, user} ->
        %{
          "username" => user["login"],
          "avatar_url" => user["avatar_url"],
          "name" => user["name"],
          "email" => user["email"] || noreply_email(user["login"])
        }

      {:error, _} ->
        %{}
    end
  end

  defp noreply_email(nil), do: nil
  defp noreply_email(login), do: "#{login}@users.noreply.github.com"

  defp github_api_get(token, path, params \\ []) do
    case Req.get(
           url: "https://api.github.com#{path}",
           headers: [
             {"authorization", "Bearer #{token}"},
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"}
           ],
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

  defp github_api_post(token, path, body) do
    case Req.post(
           url: "https://api.github.com#{path}",
           headers: [
             {"authorization", "Bearer #{token}"},
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"}
           ],
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
end
