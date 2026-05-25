defmodule Fizz.Steps.RegistryOperationDefinitionsTest do
  use ExUnit.Case, async: true

  alias Fizz.Steps.{Registry, Type}

  describe "operation-backed step types" do
    test "Google Sheets actions are registered with the generic operation executor" do
      assert {:ok, append_row} = Registry.get("google_sheets_append_row")
      assert {:ok, read_rows} = Registry.get("google_sheets_read_rows")

      assert {:ok, Fizz.Integrations.OperationExecutor} = Type.executor_module(append_row)
      assert {:ok, Fizz.Integrations.OperationExecutor} = Type.executor_module(read_rows)
    end

    test "operation-backed steps keep their existing default configuration" do
      assert Registry.get_default_config("google_sheets_append_row") ==
               Fizz.Steps.Executors.GoogleSheetsAppendRow.default_config()

      assert Registry.get_default_config("google_sheets_read_rows") ==
               Fizz.Steps.Executors.GoogleSheetsReadRows.default_config()
    end
  end
end
