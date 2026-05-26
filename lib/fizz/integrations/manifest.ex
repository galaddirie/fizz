defmodule Fizz.Integrations.Manifest do
  @moduledoc """
  Generated manifest of built-in integration catalog modules.

  Regenerate with `mix fizz.gen.integration_manifest`.
  """

  alias Fizz.Integrations.{
    CredentialRequirement,
    Definition,
    OperationDefinition,
    ResolverDefinition,
    RetryPolicy,
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
    operations = operation_definitions()

    %{
      providers:
        Fizz.Integrations.ProviderCatalog.providers() |> Enum.map(&provider_definition/1),
      credentials: credential_definitions() |> Definition.validate_credentials!(),
      integrations: integration_definitions(),
      operations: operations,
      triggers: trigger_definitions(),
      resolvers: resolver_definitions(),
      versions: operation_versions(operations)
    }
  end

  @spec operation_definitions() :: [OperationDefinition.t()]
  def operation_definitions do
    [
      operation_definition(
        Fizz.Steps.Executors.GoogleSheetsAppendRow,
        Fizz.Integrations.Google.Sheets.Actions.AppendRow,
        "google_sheets.append_row",
        "google_sheets_append_row"
      ),
      operation_definition(
        Fizz.Steps.Executors.GoogleSheetsReadRows,
        Fizz.Integrations.Google.Sheets.Actions.ReadRows,
        "google_sheets.read_rows",
        "google_sheets_read_rows"
      )
    ]
    |> Definition.validate_operations!()
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
        module: Fizz.Integrations.CredentialsResolver
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
      module: provider.oauth_module || provider.api_key_module
    }
  end

  defp credential_definitions do
    Fizz.Integrations.ProviderCatalog.providers()
    |> Enum.map(&provider_definition/1)
    |> Enum.map(fn provider ->
      %Definition.Credential{
        id: provider.id,
        provider: provider.id,
        auth_type: provider.type,
        display: %{label: provider.label, icon: provider.logo_path},
        ui_schema: credential_ui_schema(provider),
        test: credential_test(provider)
      }
    end)
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

  defp operation_definition(step_module, operation_module, operation_id, step_type_id) do
    step_type = step_module.__step_definition__()

    %OperationDefinition{
      id: operation_id,
      step_type_id: step_type_id,
      version: 1,
      provider: "google_oauth",
      integration: "google_sheets",
      kind: :action,
      module: operation_module,
      auth: credential_requirements(step_type.config_schema),
      default_config: step_module.default_config(),
      depends_on: schema_extension_index(step_type.config_schema, "depends_on"),
      field_display: schema_extension_index(step_type.config_schema, "display"),
      input_schema: step_type.input_schema,
      display: %{
        name: step_type.name,
        category: step_type.category,
        icon: step_type.icon,
        description: step_type.description
      },
      config_schema: step_type.config_schema,
      output_schema: step_type.output_schema,
      resource_locators: schema_extension_index(step_type.config_schema, "resource_locator"),
      resource_mappers: schema_extension_index(step_type.config_schema, "resource_mapper"),
      retry: %RetryPolicy{max_attempts: 1, backoff: :none}
    }
  end

  defp schema_extension_index(config_schema, key) do
    config_schema
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {field, property} ->
      case schema_extension(property, key) do
        nil -> []
        value -> [{field, value}]
      end
    end)
    |> Map.new()
  end

  defp schema_extension(property, key) when is_map(property) do
    Map.get(property, key) || get_in(property, ["ui", key])
  end

  defp schema_extension(_property, _key), do: nil

  defp credential_requirements(config_schema) do
    config_schema
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {key, schema} ->
      case get_in(schema, ["ui", "component"]) do
        "slot" -> [credential_requirement(key, schema)]
        _component -> []
      end
    end)
  end

  defp credential_requirement(key, schema) do
    ui = Map.fetch!(schema, "ui")
    spec = Map.fetch!(ui, "spec")

    %CredentialRequirement{
      key: key,
      provider: Map.fetch!(spec, "provider"),
      auth_type: auth_type!(Map.fetch!(spec, "auth_type")),
      slot_key: Map.fetch!(ui, "slot_key"),
      required: true,
      label: Map.get(schema, "title")
    }
  end

  defp auth_type!("oauth"), do: :oauth
  defp auth_type!("api_key"), do: :api_key

  defp credential_ui_schema(%Definition.Provider{type: :api_key} = provider) do
    %{
      "type" => "object",
      "required" => ["secret"],
      "properties" => %{
        "secret" => %{
          "type" => "string",
          "title" => "#{provider.label} API key",
          "writeOnly" => true,
          "ui" => %{
            "component" => "password",
            "autocomplete" => "new-password",
            "placeholder" => api_key_placeholder(provider.id),
            "order" => 10
          }
        }
      }
    }
  end

  defp credential_ui_schema(%Definition.Provider{type: :oauth}) do
    %{"type" => "object", "properties" => %{}}
  end

  defp credential_test(%Definition.Provider{type: :api_key, module: module})
       when is_atom(module) do
    %{"type" => "api_key", "module" => Atom.to_string(module), "operation" => "check_connection"}
  end

  defp credential_test(%Definition.Provider{type: :api_key} = provider) do
    %{"type" => "api_key", "provider" => provider.id, "operation" => "vault_lookup"}
  end

  defp credential_test(%Definition.Provider{type: :oauth} = provider) do
    %{"type" => "oauth", "provider" => provider.id, "operation" => "connection_status"}
  end

  defp api_key_placeholder("openai_api_key"), do: "sk-..."
  defp api_key_placeholder("anthropic_api_key"), do: "sk-ant-..."
  defp api_key_placeholder("github_api_key"), do: "ghp_..."
  defp api_key_placeholder(_provider_id), do: "Enter API key"

  defp operation_versions(operations) do
    operations
    |> Enum.group_by(& &1.step_type_id, & &1.version)
    |> Enum.map(fn {step_type_id, versions} -> {step_type_id, Enum.sort(versions)} end)
    |> Map.new()
  end
end
