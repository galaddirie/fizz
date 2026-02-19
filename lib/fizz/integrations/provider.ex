defmodule Fizz.Integrations.Provider do
  @moduledoc """
  Behaviour for external integration providers (GitHub, GitLab, Slack, etc.).

  Each provider implements connection checking, token fetching, and optionally
  git-specific or API-specific operations.
  """

  alias Fizz.Accounts.Scope

  @type connection_status :: %{
          active: boolean(),
          scopes: [String.t()],
          missing_scopes: [String.t()],
          provider_metadata: map(),
          error: term() | nil
        }

  @type token_result :: %{
          required(:access_token) => String.t(),
          required(:expires_at) => String.t() | nil,
          required(:scopes) => [String.t()],
          required(:missing_scopes) => [String.t()],
          optional(:api_credential_id) => String.t(),
          optional(:credential_id) => String.t()
        }

  @callback provider_id() :: String.t()
  @callback display_name() :: String.t()
  @callback check_connection(Scope.t(), organization_id :: String.t() | nil) ::
              {:ok, connection_status()} | {:error, term()}
  @callback fetch_token(Scope.t(), organization_id :: String.t() | nil) ::
              {:ok, token_result()} | {:error, term()}
  @callback network_domains() :: [String.t()]

  @optional_callbacks list_repos: 2, create_pull_request: 2

  @callback list_repos(Scope.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback create_pull_request(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
end
