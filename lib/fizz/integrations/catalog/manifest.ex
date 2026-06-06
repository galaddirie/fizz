defmodule Fizz.Integrations.Catalog.Manifest do
  @moduledoc """
  Generated manifest of built-in integration catalog modules.

  Regenerate with `mix fizz.gen.integration_manifest`.
  """

  alias Fizz.Integrations.Catalog.Definitions
  alias Fizz.Integrations.Catalog.Definitions.{Resolver, Trigger}

  @spec provider_modules() :: [module()]
  def provider_modules do
    [
      Fizz.Integrations.Auth.Providers.GitHubOAuth,
      Fizz.Integrations.Auth.Providers.GitHubApiKey,
      Fizz.Integrations.Auth.Providers.OpenAIApiKey,
      Fizz.Integrations.Auth.Providers.AnthropicApiKey,
      Fizz.Integrations.Auth.Providers.SlackOAuth,
      Fizz.Integrations.Auth.Providers.GoogleOAuth,
      Fizz.Integrations.Auth.Providers.MicrosoftOAuth,
      Fizz.Integrations.Auth.Providers.NotionOAuth,
      Fizz.Integrations.Auth.Providers.BoxOAuth,
      Fizz.Integrations.Auth.Providers.CustomApiKey
    ]
  end

  @spec integration_modules() :: [module()]
  def integration_modules do
    [
      Fizz.Integrations.Library.Fizz,
      Fizz.Integrations.Library.Anthropic,
      Fizz.Integrations.Library.Box,
      Fizz.Integrations.Library.GitHub,
      Fizz.Integrations.Library.Google.Docs,
      Fizz.Integrations.Library.Google.Drive,
      Fizz.Integrations.Library.Google.Gmail,
      Fizz.Integrations.Library.Google.Sheets,
      Fizz.Integrations.Library.Google.Slides,
      Fizz.Integrations.Library.Microsoft.OneDrive,
      Fizz.Integrations.Library.Microsoft.Outlook,
      Fizz.Integrations.Library.Microsoft.PowerPoint,
      Fizz.Integrations.Library.Microsoft.SharePoint,
      Fizz.Integrations.Library.Microsoft.Teams,
      Fizz.Integrations.Library.Notion,
      Fizz.Integrations.Library.OpenAI,
      Fizz.Integrations.Library.Slack
    ]
  end

  @spec step_executor_modules() :: [module()]
  def step_executor_modules do
    integration_modules()
    |> Enum.flat_map(& &1.step_modules())
  end

  @spec chat_model_provider_modules() :: [module()]
  def chat_model_provider_modules do
    [
      Fizz.Integrations.Library.OpenAI.ChatModelProvider,
      Fizz.Integrations.Library.Anthropic.ChatModelProvider
    ]
  end

  @spec definitions() :: map()
  def definitions do
    %{
      providers:
        Fizz.Integrations.Auth.ProviderCatalog.providers()
        |> Enum.map(&provider_definition/1)
        |> Definitions.validate_providers!(),
      integrations: integration_definitions(),
      triggers: trigger_definitions(),
      resolvers: resolver_definitions()
    }
  end

  @spec trigger_definitions() :: [map()]
  def trigger_definitions do
    [
      %Trigger{
        id: "google_sheets.row_change",
        step_type_id: "google_sheets_trigger",
        version: 1,
        provider: "google_oauth",
        integration: "google_sheets",
        module: Fizz.Integrations.Library.Google.Sheets.Triggers.RowChange
      }
    ]
  end

  @spec resolver_definitions() :: [map()]
  def resolver_definitions do
    [
      %Resolver{
        id: "google_sheets.columns",
        provider: "google_oauth",
        integration: "google_sheets",
        module: Fizz.Integrations.Library.Google.Sheets.ColumnsResolver
      },
      %Resolver{
        id: "openai.models",
        provider: "openai_api_key",
        integration: "openai",
        module: Fizz.Integrations.Library.OpenAI.ModelResolver
      },
      %Resolver{
        id: "anthropic.models",
        provider: "anthropic_api_key",
        integration: "anthropic",
        module: Fizz.Integrations.Library.Anthropic.ModelResolver
      },
      %Resolver{
        id: "credentials",
        module: Fizz.Fields.Credential
      }
    ]
  end

  defp provider_definition(provider) do
    %Definitions.Provider{
      id: provider.id,
      label: provider.label,
      type: provider.type,
      logo_path: provider.logo_path,
      custom: provider.custom,
      module: provider.oauth_module || provider.api_key_module,
      credential_fields: provider.credential_fields,
      credential_test: provider.credential_test
    }
  end

  defp integration_definitions do
    Enum.map(integration_modules(), fn module ->
      %Definitions.Integration{
        id: module.id(),
        display_name: module.display_name(),
        provider_id: module.provider_id(),
        module: module,
        actions: module.actions(),
        triggers: module.triggers(),
        step_modules: module.step_modules()
      }
    end)
  end
end
