defmodule Fizz.Integrations.Manifest do
  @moduledoc """
  Generated manifest of built-in integration catalog modules.

  Regenerate with `mix fizz.gen.integration_manifest`.
  """

  alias Fizz.Integrations.{
    Definition,
    ResolverDefinition,
    TriggerDefinition
  }

  @spec provider_modules() :: [module()]
  def provider_modules do
    [
      Fizz.Integrations.Providers.GitHubOAuth,
      Fizz.Integrations.Providers.GitHubApiKey,
      Fizz.Integrations.Providers.OpenAIApiKey,
      Fizz.Integrations.Providers.AnthropicApiKey,
      Fizz.Integrations.Providers.SlackOAuth,
      Fizz.Integrations.Providers.GoogleOAuth,
      Fizz.Integrations.Providers.MicrosoftOAuth,
      Fizz.Integrations.Providers.NotionOAuth,
      Fizz.Integrations.Providers.BoxOAuth,
      Fizz.Integrations.Providers.CustomApiKey
    ]
  end

  @spec integration_modules() :: [module()]
  def integration_modules do
    [
      Fizz.Integrations.Fizz,
      Fizz.Integrations.Anthropic,
      Fizz.Integrations.Box,
      Fizz.Integrations.GitHub,
      Fizz.Integrations.Google.Docs,
      Fizz.Integrations.Google.Drive,
      Fizz.Integrations.Google.Gmail,
      Fizz.Integrations.Google.Sheets,
      Fizz.Integrations.Google.Slides,
      Fizz.Integrations.Microsoft.OneDrive,
      Fizz.Integrations.Microsoft.Outlook,
      Fizz.Integrations.Microsoft.PowerPoint,
      Fizz.Integrations.Microsoft.SharePoint,
      Fizz.Integrations.Microsoft.Teams,
      Fizz.Integrations.Notion,
      Fizz.Integrations.OpenAI,
      Fizz.Integrations.Slack
    ]
  end

  @spec step_executor_modules() :: [module()]
  def step_executor_modules do
    integration_modules()
    |> Enum.flat_map(& &1.step_modules())
  end

  @spec definitions() :: map()
  def definitions do
    %{
      providers:
        Fizz.Integrations.ProviderCatalog.providers()
        |> Enum.map(&provider_definition/1)
        |> Definition.validate_providers!(),
      integrations: integration_definitions(),
      triggers: trigger_definitions(),
      resolvers: resolver_definitions()
    }
  end

  @spec trigger_definitions() :: [map()]
  def trigger_definitions do
    [
      %TriggerDefinition{
        id: "google_sheets.row_change",
        step_type_id: "google_sheets_trigger",
        version: 1,
        provider: "google_oauth",
        integration: "google_sheets",
        module: Fizz.Integrations.Google.Sheets.Triggers.RowChange
      }
    ]
  end

  @spec resolver_definitions() :: [map()]
  def resolver_definitions do
    [
      %ResolverDefinition{
        id: "google_sheets.columns",
        provider: "google_oauth",
        integration: "google_sheets",
        module: Fizz.Integrations.Google.Sheets.ColumnsResolver
      },
      %ResolverDefinition{
        id: "credentials",
        module: Fizz.Fields.Credential
      }
    ]
  end

  defp provider_definition(provider) do
    %Definition.Provider{
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
      %Definition.Integration{
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
