defmodule Fizz.Integrations.CatalogTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.{
    Catalog,
    Manifest,
    OperationDefinition,
    StepTypeAdapter
  }

  alias Fizz.Fields

  describe "catalog lookups" do
    test "catalog starts under supervision and exposes provider definitions" do
      assert {:ok, provider} = Catalog.provider("google_oauth")
      assert provider.id == "google_oauth"
      assert provider.type == :oauth
    end

    test "catalog exposes provider field, integration, operation, trigger, resolver, and version metadata" do
      refute function_exported?(Catalog, :credential, 1)
      refute function_exported?(Catalog, :credentials, 0)

      assert {:ok, openai_provider} = Catalog.provider("openai_api_key")
      credential_schema = Fields.to_schema(openai_provider.credential_fields)

      assert credential_schema["required"] == ["secret"]
      assert get_in(credential_schema, ["properties", "secret", "writeOnly"]) == true

      assert get_in(credential_schema, ["properties", "secret", "ui", "component"]) ==
               "password"

      assert openai_provider.credential_test["operation"] == "check_connection"

      assert {:ok, integration} = Catalog.integration("google_sheets")
      assert integration.module == Fizz.Integrations.Google.Sheets

      assert {:ok, %OperationDefinition{} = operation} =
               Catalog.operation("google_sheets.append_row")

      assert operation.step_type_id == "google_sheets_append_row"
      assert operation.module == Fizz.Integrations.Google.Sheets.Actions.AppendRow

      assert {:ok, trigger} = Catalog.trigger("google_sheets.row_change")
      assert trigger.module == Fizz.Integrations.Google.Sheets.Triggers.RowChange

      assert {:ok, resolver} = Catalog.resolver("google_sheets.columns")
      assert resolver.module == Fizz.Integrations.Google.Sheets.ColumnsResolver

      assert {:ok, version} = Catalog.version("google_sheets_append_row")
      assert version.versions == [1]
    end

    test "catalog resolves the latest operation for a step type" do
      assert {:ok, %OperationDefinition{} = operation} =
               Catalog.operation_for_step_type("google_sheets_append_row")

      assert operation.id == "google_sheets.append_row"
      assert operation.version == 1

      assert {:ok, ^operation} = Catalog.operation_for_step_type("google_sheets_append_row", 1)
    end
  end

  describe "manifest definitions" do
    test "manifest exposes current built-in module lists" do
      assert Fizz.Integrations.Providers.GoogleOAuth in Manifest.provider_modules()
      assert Fizz.Integrations.Google.Sheets in Manifest.integration_modules()
      assert Fizz.Steps.Executors.ManualInput in Manifest.step_executor_modules()
      refute Fizz.Integrations.Google.Sheets.Actions.AppendRow in Manifest.step_executor_modules()
      refute Fizz.Integrations.Google.Sheets.Actions.ReadRows in Manifest.step_executor_modules()
    end

    test "manifest operation definitions validate and include typed fields" do
      assert %OperationDefinition{} =
               operation =
               Enum.find(Manifest.operation_definitions(), &(&1.id == "google_sheets.append_row"))

      credential_field = Enum.find(operation.fields, &(&1.key == "credential_ref"))

      assert credential_field.type == :credential
      assert credential_field.credential.provider == "google_oauth"
      assert credential_field.credential.auth_type == :oauth

      values_field = Enum.find(operation.fields, &(&1.key == "values"))

      assert values_field.depends_on == [
               "credential_ref",
               "spreadsheet_id",
               "sheet_name",
               "table_id"
             ]

      spreadsheet_field = Enum.find(operation.fields, &(&1.key == "spreadsheet_id"))

      assert spreadsheet_field.resource_locator["kind"] ==
               "google_sheets.spreadsheet"

      assert values_field.resource_mapper["kind"] == "google_sheets.row_values"

      assert values_field.resource_mapper["lookups"]["primary_resource"]["mode"] ==
               "sheets"

      assert values_field.resource_mapper["lookups"]["schema_resource"]["mode"] ==
               "tables"

      assert operation.retry.max_attempts == 3
      assert operation.retry.backoff == :exponential
      assert operation.retry.retry_on == [:rate_limit, :network, :transient]
    end
  end

  describe "step type adapters" do
    test "adapter produces step types from existing executor modules" do
      assert %Fizz.Steps.Type{id: "manual_input"} =
               StepTypeAdapter.from_executor_module!(Fizz.Steps.Executors.ManualInput)
    end

    test "adapter produces step types from operation definitions" do
      operation =
        Enum.find(Manifest.operation_definitions(), &(&1.id == "google_sheets.append_row"))

      step_type =
        StepTypeAdapter.from_operation_definition!(operation,
          executor: Fizz.Integrations.OperationExecutor
        )

      assert step_type.id == "google_sheets_append_row"
      assert step_type.name =~ "Append Row"
      assert step_type.executor == "Elixir.Fizz.Integrations.OperationExecutor"
      assert step_type.step_kind == operation.kind
      assert step_type.input_schema == operation.input_schema
    end
  end
end
