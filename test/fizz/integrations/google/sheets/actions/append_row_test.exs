defmodule Fizz.Integrations.Google.Sheets.Actions.AppendRowTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Google.Sheets.Actions.AppendRow
  alias Fizz.Integrations.OperationExecutor

  describe "execute/3" do
    test "requires a resolved credential ref through the operation executor" do
      config = %{
        "spreadsheet_id" => "sheet_123",
        "values" => %{"A" => "1"}
      }

      assert {:error, :credential_ref_required} =
               OperationExecutor.execute(config, %{}, %{type_id: "google_sheets_append_row"})
    end
  end

  describe "build_row/2" do
    test "passes lists through unchanged" do
      assert {:ok, ["a", "b", "c"]} = AppendRow.build_row(["a", "b", "c"], ["ignored"])
    end

    test "projects map values onto the sheet's header order" do
      values = %{"Email" => "ada@example.com", "Name" => "Ada"}
      headers = ["Name", "Email", "Joined"]

      assert {:ok, ["Ada", "ada@example.com", ""]} = AppendRow.build_row(values, headers)
    end

    test "fills missing columns with empty strings" do
      assert {:ok, ["", "", ""]} = AppendRow.build_row(%{}, ["A", "B", "C"])
    end

    test "ignores keys that do not match any column header" do
      values = %{"Name" => "Ada", "Phone" => "555-0100"}
      headers = ["Name", "Email"]

      assert {:ok, ["Ada", ""]} = AppendRow.build_row(values, headers)
    end

    test "returns :invalid_row_values for non-map, non-list input" do
      assert {:error, :invalid_row_values} = AppendRow.build_row("not a row", ["A"])
      assert {:error, :invalid_row_values} = AppendRow.build_row(nil, ["A"])
    end
  end

  describe "build_rows/2" do
    test "wraps a positional row" do
      assert {:ok, [["a", "b", "c"]]} = AppendRow.build_rows(["a", "b", "c"], ["ignored"])
    end

    test "passes multiple positional rows through" do
      rows = [["Ada", "ada@example.com"], ["Grace", "grace@example.com"]]

      assert {:ok, ^rows} = AppendRow.build_rows(rows, ["ignored"])
    end

    test "projects multiple mapped rows onto the sheet header order" do
      rows = [
        %{"Email" => "ada@example.com", "Name" => "Ada"},
        %{"Email" => "grace@example.com", "Name" => "Grace"}
      ]

      assert {:ok, [["Ada", "ada@example.com"], ["Grace", "grace@example.com"]]} =
               AppendRow.build_rows(rows, ["Name", "Email"])
    end

    test "wraps a mapped row" do
      assert {:ok, [["Ada", ""]]} =
               AppendRow.build_rows(%{"Name" => "Ada"}, ["Name", "Email"])
    end

    test "rejects mixed row collections" do
      assert {:error, :invalid_row_values} =
               AppendRow.build_rows([%{"Name" => "Ada"}, ["Grace"]], ["Name"])

      assert {:error, :invalid_row_values} =
               AppendRow.build_rows([["Ada"], %{"Name" => "Grace"}], ["Name"])
    end
  end

  describe "definition/0" do
    test "exposes the resource mapper UI hint on the values field" do
      schema = AppendRow.definition().config_schema
      values_field = get_in(schema, ["properties", "values"])

      assert get_in(values_field, ["ui", "component"]) == "resource_mapper"

      assert values_field["depends_on"] == [
               "credential_ref",
               "spreadsheet_id",
               "sheet_name",
               "table_id"
             ]

      assert get_in(values_field, ["resource_mapper", "kind"]) == "google_sheets.row_values"

      assert get_in(values_field, ["ui", "resolver"]) ==
               Fizz.Integrations.Google.Sheets.ColumnsResolver
    end

    test "keeps sheet and table selection state hidden because the mapper owns it" do
      schema = AppendRow.definition().config_schema
      sheet_name_field = get_in(schema, ["properties", "sheet_name"])
      table_id_field = get_in(schema, ["properties", "table_id"])

      assert sheet_name_field["default"] == ""
      assert get_in(sheet_name_field, ["ui", "component"]) == "hidden"
      assert table_id_field["default"] == ""
      assert get_in(table_id_field, ["ui", "component"]) == "hidden"
    end
  end
end
