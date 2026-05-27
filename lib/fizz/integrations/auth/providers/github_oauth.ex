defmodule Fizz.Integrations.Auth.Providers.GitHubOAuth do
  @moduledoc """
  GitHub integration provider. Uses WorkOS Pipes for OAuth token management.
  """

  @behaviour Fizz.Integrations.Contracts.Provider

  alias Fizz.Accounts
  alias Fizz.Integrations.Library.GitHub.Client
  alias Fizz.Integrations.Auth.ProviderDefinition

  require Logger

  @impl true
  def provider_id, do: "github_oauth"

  @impl true
  def display_name, do: "GitHub"

  @impl true
  def definition do
    ProviderDefinition.oauth(__MODULE__,
      id: provider_id(),
      label: display_name(),
      logo_path: "/images/github.svg"
    )
  end

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

  defp fetch_user_metadata(nil), do: %{}

  defp fetch_user_metadata(token) do
    case Client.get_user(token) do
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
end
