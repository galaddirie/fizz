defmodule Fizz.ExecutionsTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Fizz.Executions.Execution
  alias Fizz.Executions.StepExecution

  describe "changesets" do
    test "execution changeset requires trigger" do
      changeset =
        Execution.changeset(%Execution{}, %{
          workflow_id: Ecto.UUID.generate(),
          status: :pending,
          execution_type: :preview
        })

      refute changeset.valid?
      assert %{trigger: ["can't be blank"]} = errors_on(changeset)
    end

    test "step execution changeset allows output_item_count = 0" do
      attrs = %{
        execution_id: Ecto.UUID.generate(),
        step_id: "step_1",
        step_type_id: "manual_input",
        status: :completed,
        output_item_count: 0
      }

      changeset = StepExecution.changeset(%StepExecution{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :output_item_count) == 0
    end

    test "step execution changeset rejects negative counters" do
      attrs = %{
        execution_id: Ecto.UUID.generate(),
        step_id: "step_1",
        step_type_id: "manual_input",
        status: :pending,
        output_item_count: -1,
        item_index: -1,
        items_total: 0
      }

      changeset = StepExecution.changeset(%StepExecution{}, attrs)

      refute changeset.valid?

      assert "must be greater than or equal to %{number}" in errors_on(changeset).output_item_count

      assert "must be greater than or equal to %{number}" in errors_on(changeset).item_index
      assert "must be greater than or equal to %{number}" in errors_on(changeset).items_total
    end
  end

  defp errors_on(changeset) do
    traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
