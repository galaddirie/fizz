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
      Fizz.Integrations.Google.Sheets
    ]
  end

  @spec step_executor_modules() :: [module()]
  def step_executor_modules do
    [
      Fizz.Steps.Executors.ManualInput,
      Fizz.Steps.Executors.OnChatTrigger,
      Fizz.Steps.Executors.HttpRequest,
      Fizz.Steps.Executors.JsonParser,
      Fizz.Steps.Executors.DataFilter,
      Fizz.Steps.Executors.DataTransform,
      Fizz.Steps.Executors.DataOutput,
      Fizz.Steps.Executors.Condition,
      Fizz.Steps.Executors.Switch,
      Fizz.Steps.Executors.Format,
      Fizz.Steps.Executors.Debug,
      Fizz.Steps.Executors.Math,
      Fizz.Steps.Executors.Aggregator,
      Fizz.Steps.Executors.Splitter,
      Fizz.Steps.Executors.Join,
      Fizz.Steps.Executors.ScheduleTrigger,
      Fizz.Steps.Executors.Wait,
      Fizz.Steps.Executors.AIAgent,
      Fizz.Steps.Executors.OpenAIModel,
      Fizz.Steps.Executors.AnthropicModel,
      Fizz.Steps.Executors.AIStructureSchema,
      Fizz.Steps.Executors.AIToolHttp,
      Fizz.Steps.Executors.OpenAIImageGeneration,
      Fizz.Steps.Executors.AnthropicVisionAnalysis,
      Fizz.Steps.Executors.GmailTrigger,
      Fizz.Steps.Executors.GmailSendEmail,
      Fizz.Steps.Executors.GmailReplyEmail,
      Fizz.Steps.Executors.SlackTrigger,
      Fizz.Steps.Executors.SlackSendMessage,
      Fizz.Steps.Executors.SlackCreateChannel,
      Fizz.Steps.Executors.GoogleDocsTrigger,
      Fizz.Steps.Executors.GoogleDocsCreateDoc,
      Fizz.Steps.Executors.GoogleDocsAppendText,
      Fizz.Steps.Executors.GoogleSheetsTrigger,
      Fizz.Integrations.Google.Sheets.Actions.ReadRows,
      Fizz.Integrations.Google.Sheets.Actions.AppendRow,
      Fizz.Steps.Executors.GoogleSlidesCreatePresentation,
      Fizz.Steps.Executors.GoogleSlidesAddSlide,
      Fizz.Steps.Executors.GoogleDriveUploadFile,
      Fizz.Steps.Executors.NotionTrigger,
      Fizz.Steps.Executors.NotionCreatePage,
      Fizz.Steps.Executors.NotionUpdatePage,
      Fizz.Steps.Executors.GitHubTrigger,
      Fizz.Steps.Executors.GitHubCreateIssue,
      Fizz.Steps.Executors.GitHubCreatePR,
      Fizz.Steps.Executors.OutlookTrigger,
      Fizz.Steps.Executors.OutlookSendEmail,
      Fizz.Steps.Executors.TeamsTrigger,
      Fizz.Steps.Executors.TeamsSendMessage,
      Fizz.Steps.Executors.SharePointUploadFile,
      Fizz.Steps.Executors.OneDriveUploadFile,
      Fizz.Steps.Executors.PowerPointCreatePresentation,
      Fizz.Steps.Executors.BoxUploadFile
    ]
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
        triggers: module.triggers()
      }
    end)
  end
end
