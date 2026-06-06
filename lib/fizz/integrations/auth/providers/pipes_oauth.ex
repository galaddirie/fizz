defmodule Fizz.Integrations.Auth.Providers.PipesOAuth do
  @moduledoc false

  alias Fizz.Accounts

  @spec check_connection(Fizz.Accounts.Scope.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def check_connection(_scope, nil, _provider_slug), do: {:error, :organization_scope_required}

  def check_connection(scope, organization_id, provider_slug)
      when is_binary(organization_id) and is_binary(provider_slug) do
    case Accounts.get_pipes_access_token(scope, provider_slug, organization_id) do
      {:ok, %{active: true} = result} ->
        {:ok,
         %{
           active: true,
           scopes: result[:scopes] || [],
           missing_scopes: result[:missing_scopes] || [],
           provider_metadata: %{},
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

  @spec fetch_token(Fizz.Accounts.Scope.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def fetch_token(_scope, nil, _provider_slug), do: {:error, :organization_scope_required}

  def fetch_token(scope, organization_id, provider_slug)
      when is_binary(organization_id) and is_binary(provider_slug) do
    case Accounts.get_pipes_access_token(scope, provider_slug, organization_id) do
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

      {:ok, _result} ->
        {:error, :no_access_token}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
