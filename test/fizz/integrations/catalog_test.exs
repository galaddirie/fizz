defmodule Fizz.Integrations.CatalogTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.{
    Catalog,
    Manifest,
    OperationDefinition,
    StepTypeAdapter
  }

  describe "catalog lookups" do
    test "catalog starts under supervision and exposes provider definitions" do
      assert {:ok, provider} = Catalog.provider("google_oauth")
      assert provider.id == "google_oauth"
      assert provider.type == :oauth
    end

    test "catalog exposes credential, integration, operation, trigger, resolver, and version metadata" do
      assert {:ok, credential} = Catalog.credential("openai_api_key")
      assert credential.auth_type == :api_key
      assert credential.ui_schema["required"] == ["secret"]
      assert get_in(credential.ui_schema, ["properties", "secret", "writeOnly"]) == true

      assert get_in(credential.ui_schema, ["properties", "secret", "ui", "component"]) ==
               "password"

      assert credential.test["operation"] == "check_connection"

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
      refute Fizz.Steps.Executors.GoogleSheetsAppendRow in Manifest.step_executor_modules()
      refute Fizz.Steps.Executors.GoogleSheetsReadRows in Manifest.step_executor_modules()
    end

    test "manifest operation definitions validate and include credential requirements" do
      assert %OperationDefinition{} =
               operation =
               Enum.find(Manifest.operation_definitions(), &(&1.id == "google_sheets.append_row"))

      assert [
               %Fizz.Integrations.CredentialRequirement{
                 key: "credential_ref",
                 provider: "google_oauth",
                 auth_type: :oauth
               }
             ] = operation.auth
    end
  end

  describe "step type adapters" do
    test "adapter produces step types from existing executor modules" do
      assert %Fizz.Steps.Type{id: "google_sheets_append_row"} =
               StepTypeAdapter.from_executor_module!(Fizz.Steps.Executors.GoogleSheetsAppendRow)
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
