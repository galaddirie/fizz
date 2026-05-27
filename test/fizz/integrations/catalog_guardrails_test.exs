defmodule Fizz.Integrations.CatalogGuardrailsTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.ProviderCatalog
  alias Fizz.Steps.Registry
  alias Fizz.Steps.Type

  @expected_provider_ids [
    "anthropic_api_key",
    "box_oauth",
    "custom_api_key",
    "github_api_key",
    "github_oauth",
    "google_oauth",
    "microsoft_oauth",
    "notion_oauth",
    "openai_api_key",
    "slack_oauth"
  ]

  @expected_integration_ids [
    "google_sheets"
  ]

  @expected_step_type_ids [
    "aggregator",
    "ai_agent",
    "ai_structure_schema",
    "ai_tool_http",
    "anthropic_model",
    "anthropic_vision_analysis",
    "box_upload_file",
    "condition",
    "data_filter",
    "data_output",
    "data_transform",
    "debug",
    "format",
    "github_create_issue",
    "github_create_pr",
    "github_trigger",
    "gmail_reply_email",
    "gmail_send_email",
    "gmail_trigger",
    "google_docs_append_text",
    "google_docs_create_doc",
    "google_docs_trigger",
    "google_drive_upload_file",
    "google_sheets_append_row",
    "google_sheets_read_rows",
    "google_sheets_trigger",
    "google_slides_add_slide",
    "google_slides_create_presentation",
    "http_request",
    "join",
    "json_parser",
    "manual_input",
    "math",
    "notion_create_page",
    "notion_trigger",
    "notion_update_page",
    "on_chat_trigger",
    "onedrive_upload_file",
    "openai_image_generation",
    "openai_model",
    "outlook_send_email",
    "outlook_trigger",
    "powerpoint_create_presentation",
    "schedule_trigger",
    "sharepoint_upload_file",
    "slack_create_channel",
    "slack_send_message",
    "slack_trigger",
    "splitter",
    "switch",
    "teams_send_message",
    "teams_trigger",
    "wait"
  ]

  @expected_credential_requirements [
    {"anthropic_model", "credential_ref", "anthropic_api_key", "api_key", "auth"},
    {"anthropic_vision_analysis", "credential_ref", "anthropic_api_key", "api_key", "auth"},
    {"box_upload_file", "credential_ref", "box_oauth", "oauth", "auth"},
    {"github_create_issue", "credential_ref", "github_oauth", "oauth", "auth"},
    {"github_create_pr", "credential_ref", "github_oauth", "oauth", "auth"},
    {"github_trigger", "credential_ref", "github_oauth", "oauth", "auth"},
    {"gmail_reply_email", "credential_ref", "google_oauth", "oauth", "auth"},
    {"gmail_send_email", "credential_ref", "google_oauth", "oauth", "auth"},
    {"gmail_trigger", "credential_ref", "google_oauth", "oauth", "auth"},
    {"google_docs_append_text", "credential_ref", "google_oauth", "oauth", "auth"},
    {"google_docs_create_doc", "credential_ref", "google_oauth", "oauth", "auth"},
    {"google_docs_trigger", "credential_ref", "google_oauth", "oauth", "auth"},
    {"google_drive_upload_file", "credential_ref", "google_oauth", "oauth", "auth"},
    {"google_sheets_append_row", "credential_ref", "google_oauth", "oauth", "auth"},
    {"google_sheets_read_rows", "credential_ref", "google_oauth", "oauth", "auth"},
    {"google_sheets_trigger", "credential_ref", "google_oauth", "oauth", "auth"},
    {"google_slides_add_slide", "credential_ref", "google_oauth", "oauth", "auth"},
    {"google_slides_create_presentation", "credential_ref", "google_oauth", "oauth", "auth"},
    {"notion_create_page", "credential_ref", "notion_oauth", "oauth", "auth"},
    {"notion_trigger", "credential_ref", "notion_oauth", "oauth", "auth"},
    {"notion_update_page", "credential_ref", "notion_oauth", "oauth", "auth"},
    {"onedrive_upload_file", "credential_ref", "microsoft_oauth", "oauth", "auth"},
    {"openai_image_generation", "credential_ref", "openai_api_key", "api_key", "auth"},
    {"openai_model", "credential_ref", "openai_api_key", "api_key", "auth"},
    {"outlook_send_email", "credential_ref", "microsoft_oauth", "oauth", "auth"},
    {"outlook_trigger", "credential_ref", "microsoft_oauth", "oauth", "auth"},
    {"powerpoint_create_presentation", "credential_ref", "microsoft_oauth", "oauth", "auth"},
    {"sharepoint_upload_file", "credential_ref", "microsoft_oauth", "oauth", "auth"},
    {"slack_create_channel", "credential_ref", "slack_oauth", "oauth", "auth"},
    {"slack_send_message", "credential_ref", "slack_oauth", "oauth", "auth"},
    {"slack_trigger", "credential_ref", "slack_oauth", "oauth", "auth"},
    {"teams_send_message", "credential_ref", "microsoft_oauth", "oauth", "auth"},
    {"teams_trigger", "credential_ref", "microsoft_oauth", "oauth", "auth"}
  ]

  @expected_ui_components [
    {"google_sheets_append_row", "sheet_name", "hidden"},
    {"google_sheets_append_row", "spreadsheet_id", "resource_locator"},
    {"google_sheets_append_row", "table_id", "hidden"},
    {"google_sheets_append_row", "values", "resource_mapper"},
    {"google_sheets_read_rows", "range", "string"},
    {"google_sheets_read_rows", "spreadsheet_id", "string"},
    {"manual_input", "test_data", "json"}
  ]

  describe "current catalog surfaces" do
    test "built-in provider IDs stay explicit" do
      assert provider_ids() == @expected_provider_ids
    end

    test "built-in product integration IDs stay explicit" do
      assert integration_ids() == @expected_integration_ids
    end

    test "built-in step type IDs stay explicit and executors load" do
      step_types = Registry.all()

      assert step_types |> Enum.map(& &1.id) |> Enum.sort() == @expected_step_type_ids

      for %Type{} = step_type <- step_types do
        assert {:ok, module} = Type.executor_module(step_type)
        assert {:module, ^module} = Code.ensure_loaded(module)
      end

      assert {:ok, append_row} = Registry.get("google_sheets_append_row")
      assert {:ok, read_rows} = Registry.get("google_sheets_read_rows")
      assert {:ok, Fizz.Integrations.OperationExecutor} = Type.executor_module(append_row)
      assert {:ok, Fizz.Integrations.OperationExecutor} = Type.executor_module(read_rows)
    end
  end

  describe "credential field shapes" do
    test "credential fields keep their provider/auth contracts" do
      assert credential_requirements() == @expected_credential_requirements
    end

    test "non-credential UI components stay explicit" do
      assert ui_components() == @expected_ui_components
    end

    test "credential fields have matching default declarations" do
      for {step_id, field, provider, auth_type, requirement_key} <- credential_requirements() do
        {:ok, step_type} = Registry.get(step_id)
        default_config = Registry.get_default_config(step_id)
        schema = get_in(step_type.config_schema, ["properties", field])

        assert %{
                 "type" => "object",
                 "ui" => %{
                   "component" => "credential",
                   "requirement_key" => ^requirement_key,
                   "provider" => ^provider,
                   "auth_type" => ^auth_type
                 }
               } = schema

        assert %{
                 "$credential" => true,
                 "requirement_key" => ^requirement_key,
                 "provider" => ^provider,
                 "auth_type" => ^auth_type
               } = Map.fetch!(default_config, field)

        assert {:ok, %{id: ^provider, type: provider_auth_type}} =
                 ProviderCatalog.provider(provider)

        assert Atom.to_string(provider_auth_type) == auth_type
      end
    end
  end

  defp provider_ids do
    ProviderCatalog.providers()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp integration_ids do
    Fizz.Integrations.Registry.all()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp credential_requirements do
    Registry.all()
    |> Enum.flat_map(&credential_requirements_for_step/1)
    |> Enum.sort()
  end

  defp ui_components do
    Registry.all()
    |> Enum.flat_map(&ui_components_for_step/1)
    |> Enum.sort()
  end

  defp credential_requirements_for_step(%Type{} = step_type) do
    step_type.config_schema
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {field, schema} ->
      case get_in(schema, ["ui", "component"]) do
        "credential" -> [credential_requirement_tuple(step_type.id, field, schema)]
        _component -> []
      end
    end)
  end

  defp credential_requirement_tuple(step_id, field, schema) do
    ui = Map.fetch!(schema, "ui")

    {
      step_id,
      field,
      Map.fetch!(ui, "provider"),
      Map.fetch!(ui, "auth_type"),
      Map.fetch!(ui, "requirement_key")
    }
  end

  defp ui_components_for_step(%Type{} = step_type) do
    step_type.config_schema
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {field, schema} ->
      case get_in(schema, ["ui", "component"]) do
        "credential" -> []
        component when is_binary(component) -> [{step_type.id, field, component}]
        _component -> []
      end
    end)
  end
end
