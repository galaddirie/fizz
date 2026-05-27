defmodule Fizz.Integrations.OperationExecutorTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.OperationError
  alias Fizz.Integrations.OperationExecutor
  alias Fizz.Steps.Executors.Behaviour
  alias Fizz.Workflows.ExecutionContext

  describe "execute/3" do
    test "step executor helper seeds type id for operation-backed steps" do
      config = %{
        "spreadsheet_id" => "sheet_123",
        "values" => ["Ada", "Lovelace"]
      }

      assert {:error, %OperationError{code: :credential_ref_required, category: :credential}} =
               Behaviour.execute("google_sheets_append_row", config, %{}, %{})
    end

    test "dispatches by step type through the integration catalog" do
      config = %{
        "spreadsheet_id" => "sheet_123",
        "values" => ["Ada", "Lovelace"]
      }

      context = %{
        type_id: "google_sheets_append_row",
        project_id: "project_123",
        user_id: "user_123",
        workos_organization_id: "org_123"
      }

      assert {:error, %OperationError{code: :credential_ref_required, category: :credential}} =
               OperationExecutor.execute(config, %{}, context)
    end

    test "dispatches an explicit operation id" do
      config = %{
        "spreadsheet_id" => "sheet_123"
      }

      assert {:error, %OperationError{code: :credential_ref_required, category: :credential}} =
               OperationExecutor.execute(config, %{}, %{
                 operation_id: "google_sheets.read_rows",
                 type_id: "google_sheets_read_rows"
               })
    end

    test "rejects explicit operation ids that do not match the step type" do
      assert {:error, {:operation_step_type_mismatch, "google_sheets.read_rows", "debug"}} =
               OperationExecutor.execute(%{}, %{}, %{
                 operation_id: "google_sheets.read_rows",
                 type_id: "debug"
               })
    end

    test "rejects invalid operation versions instead of falling back" do
      assert {:error, {:invalid_operation_version, "not-an-int"}} =
               OperationExecutor.execute(%{}, %{}, %{
                 type_id: "google_sheets_read_rows",
                 operation_version: "not-an-int"
               })
    end

    test "passes a typed execution context beside legacy context keys" do
      config = %{
        "spreadsheet_id" => "sheet_123",
        "values" => ["Ada", "Lovelace"]
      }

      execution_context = %ExecutionContext{
        type_id: "google_sheets_append_row",
        project_id: "project_123",
        user_id: "user_123",
        workos_organization_id: "org_123"
      }

      assert {:error, %OperationError{code: :credential_ref_required, category: :credential}} =
               OperationExecutor.execute(config, %{}, execution_context)
    end

    test "normalizes raw operation failures" do
      assert {:error, %OperationError{} = error} =
               OperationExecutor.execute(
                 %{"spreadsheet_id" => "sheet_123", "values" => "not-a-row"},
                 %{},
                 %{type_id: "google_sheets_append_row"}
               )

      assert error.code == :invalid_row_values
      assert error.category == :validation
    end

    test "returns an error when no operation can be resolved" do
      assert {:error, :operation_type_id_required} =
               OperationExecutor.execute(%{}, %{}, %{})

      assert {:error, {:operation_not_found, "unknown_step"}} =
               OperationExecutor.execute(%{}, %{}, %{type_id: "unknown_step"})
    end
  end
end
