defmodule Fizz.FieldsTest do
  use ExUnit.Case, async: true

  alias Fizz.Fields

  describe "validate!/1" do
    test "accepts supported field types and components" do
      fields = [
        Fields.string("string"),
        Fields.number("number"),
        Fields.boolean("boolean"),
        Fields.json("json"),
        Fields.select("select", options: [%{"label" => "One", "value" => "one"}]),
        Fields.search("search"),
        Fields.hidden("hidden"),
        Fields.password("password"),
        Fields.credential("openai_api_key", :api_key),
        Fields.resource_locator("resource_locator", %{"kind" => "test.resource"}),
        Fields.resource_mapper("resource_mapper", %{"kind" => "test.mapper"})
      ]

      assert Fields.validate!(fields) == fields
    end

    test "rejects unsupported field types and components" do
      assert_raise ArgumentError, ~r/unsupported field type/, fn ->
        Fields.field(%{key: "bad", type: :bespoke})
      end

      assert_raise ArgumentError, ~r/unsupported component/, fn ->
        Fields.field(%{key: "bad", type: :string, component: "bespoke"})
      end
    end

    test "rejects invalid credential and resource metadata" do
      assert_raise ArgumentError, ~r/requires credential metadata/, fn ->
        Fields.field(%{key: "credential_ref", type: :credential})
      end

      assert_raise ArgumentError, ~r/resource_locator field requires/, fn ->
        Fields.field(%{key: "sheet", type: :resource_locator})
      end

      assert_raise ArgumentError, ~r/resource_mapper field requires/, fn ->
        Fields.field(%{key: "values", type: :resource_mapper})
      end
    end
  end

  describe "to_schema/1" do
    test "generates password field schema" do
      schema = Fields.to_schema([Fields.password("secret", required?: true, default: "")])

      assert schema["required"] == ["secret"]
      assert get_in(schema, ["properties", "secret", "type"]) == "string"
      assert get_in(schema, ["properties", "secret", "writeOnly"]) == true
      assert get_in(schema, ["properties", "secret", "ui", "component"]) == "password"
    end

    test "generates credential field schema and default declaration" do
      field =
        Fields.credential("google_oauth", :oauth,
          key: "credential_ref",
          label: "Google Account"
        )

      property = Fields.to_schema_property(field)

      assert get_in(property, ["ui", "component"]) == "credential"
      assert get_in(property, ["ui", "provider"]) == "google_oauth"
      assert get_in(property, ["ui", "auth_type"]) == "oauth"

      assert Fields.default_value(field) == %{
               "$credential" => true,
               "requirement_key" => "auth",
               "provider" => "google_oauth",
               "auth_type" => "oauth"
             }
    end

    test "generates resource locator and mapper metadata in adapter schema" do
      locator = %{"kind" => "google_sheets.spreadsheet", "value_key" => "spreadsheet_id"}
      mapper = %{"kind" => "google_sheets.row_values"}

      schema =
        Fields.to_schema([
          Fields.resource_locator("spreadsheet_id", locator),
          Fields.resource_mapper("values", mapper, depends_on: ["spreadsheet_id"])
        ])

      assert get_in(schema, ["properties", "spreadsheet_id", "resource_locator"]) == locator
      assert get_in(schema, ["properties", "values", "resource_mapper"]) == mapper
      assert get_in(schema, ["properties", "values", "depends_on"]) == ["spreadsheet_id"]
      assert get_in(schema, ["properties", "values", "ui", "resource_mapper"]) == mapper
    end
  end
end
