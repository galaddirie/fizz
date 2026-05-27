defmodule Fizz.Integrations.CatalogTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.{
    Catalog,
    Manifest
  }

  alias Fizz.Fields
  alias Fizz.Integrations.StepRegistry, as: StepRegistry
  alias Fizz.Workflows.RetryPolicy

  describe "catalog lookups" do
    test "catalog starts under supervision and exposes provider definitions" do
      assert {:ok, provider} = Catalog.provider("google_oauth")
      assert provider.id == "google_oauth"
      assert provider.type == :oauth
    end

    test "catalog exposes provider field, integration, trigger, and resolver metadata" do
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
      assert integration.actions == ["google_sheets_read_rows", "google_sheets_append_row"]

      assert {:ok, trigger} = Catalog.trigger("google_sheets.row_change")
      assert trigger.module == Fizz.Integrations.Google.Sheets.Triggers.RowChange

      assert {:ok, resolver} = Catalog.resolver("google_sheets.columns")
      assert resolver.module == Fizz.Integrations.Google.Sheets.ColumnsResolver
    end
  end

  describe "manifest definitions" do
    test "manifest exposes current built-in module lists" do
      assert Fizz.Integrations.Providers.GoogleOAuth in Manifest.provider_modules()
      assert Fizz.Integrations.Fizz in Manifest.integration_modules()
      assert Fizz.Integrations.Google.Sheets in Manifest.integration_modules()
      assert Fizz.Integrations.Fizz.Builtins.ManualInput in Manifest.step_executor_modules()
      assert Fizz.Integrations.Google.Sheets.Actions.AppendRow in Manifest.step_executor_modules()
      assert Fizz.Integrations.Google.Sheets.Actions.ReadRows in Manifest.step_executor_modules()
    end

    test "google sheets step definitions validate and include typed fields" do
      assert {:ok, step_type} = StepRegistry.get("google_sheets_append_row")

      assert step_type.version == 1
      assert step_type.provider == Fizz.Integrations.Providers.GoogleOAuth.provider_id()
      assert step_type.integration == "google_sheets"

      assert step_type.executor ==
               Atom.to_string(Fizz.Integrations.Google.Sheets.Actions.AppendRow)

      credential_field = Enum.find(step_type.fields, &(&1.key == "credential_ref"))

      assert credential_field.type == :credential
      assert credential_field.credential.provider == "google_oauth"
      assert credential_field.credential.auth_type == :oauth

      values_field = Enum.find(step_type.fields, &(&1.key == "values"))

      assert values_field.depends_on == [
               "credential_ref",
               "spreadsheet_id",
               "sheet_name",
               "table_id"
             ]

      spreadsheet_field = Enum.find(step_type.fields, &(&1.key == "spreadsheet_id"))

      assert spreadsheet_field.resource_locator["kind"] ==
               "google_sheets.spreadsheet"

      assert values_field.resource_mapper["kind"] == "google_sheets.row_values"

      assert values_field.resource_mapper["lookups"]["primary_resource"]["mode"] ==
               "sheets"

      assert values_field.resource_mapper["lookups"]["schema_resource"]["mode"] ==
               "tables"

      assert %RetryPolicy{} = step_type.retry
      assert step_type.retry.max_attempts == 3
      assert step_type.retry.backoff == :exponential
      assert step_type.retry.retry_on == [:rate_limit, :network, :transient]
    end
  end
end
