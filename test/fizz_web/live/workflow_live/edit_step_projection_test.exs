defmodule FizzWeb.WorkflowLive.EditStepProjectionTest do
  use ExUnit.Case, async: true

  alias Fizz.Runtime.Serializer
  alias FizzWeb.WorkflowLive.Edit.EditStepProjection

  test "preserves a failed summary row when itemized cancellations arrive" do
    execution_id = Ecto.UUID.generate()

    initial = [
      running_step_execution(execution_id, 0),
      running_step_execution(execution_id, 1)
    ]

    updated =
      initial
      |> EditStepProjection.apply_event(execution_id, :step_failed, %{
        execution_id: execution_id,
        step_id: "fan_out_step",
        status: :failed,
        completed_at: ~U[2026-03-01 00:00:02Z],
        error: %{"type" => "step_failure"}
      })
      |> EditStepProjection.apply_event(execution_id, :step_cancelled, %{
        execution_id: execution_id,
        step_id: "fan_out_step",
        status: :cancelled,
        item_index: 0,
        items_total: 2,
        completed_at: ~U[2026-03-01 00:00:03Z]
      })
      |> EditStepProjection.apply_event(execution_id, :step_cancelled, %{
        execution_id: execution_id,
        step_id: "fan_out_step",
        status: :cancelled,
        item_index: 1,
        items_total: 2,
        completed_at: ~U[2026-03-01 00:00:03Z]
      })

    assert %{status: :failed, item_index: nil} =
             Enum.find(updated, &is_nil(Map.get(&1, :item_index)))

    assert 2 == Enum.count(updated, &(Map.get(&1, :status) == :cancelled))
    refute Enum.any?(updated, &(Map.get(&1, :status) == :running))
  end

  test "keeps failed status when a later cancelled event targets the same summary row" do
    execution_id = Ecto.UUID.generate()

    updated =
      [
        %{
          id: "#{execution_id}:fan_out_step:1",
          execution_id: execution_id,
          step_id: "fan_out_step",
          status: :failed,
          attempt: 1,
          item_index: nil,
          error: %{"type" => "step_failure"},
          completed_at: ~U[2026-03-01 00:00:02Z],
          metadata: %{}
        }
      ]
      |> EditStepProjection.apply_event(execution_id, :step_cancelled, %{
        execution_id: execution_id,
        step_id: "fan_out_step",
        status: :cancelled,
        completed_at: ~U[2026-03-01 00:00:03Z]
      })

    assert [%{status: :failed}] = updated
  end

  test "normalizes sanitized runtime timestamps for fan-out item events" do
    execution_id = Ecto.UUID.generate()
    started_at = ~U[2026-03-01 00:00:00.123456Z]
    completed_at = ~U[2026-03-01 00:00:02.654321Z]

    [step_execution] =
      EditStepProjection.apply_event([], execution_id, :step_completed, %{
        "execution_id" => execution_id,
        "step_id" => "fan_out_step",
        "status" => "completed",
        "item_index" => 0,
        "items_total" => 2,
        "started_at" => Serializer.sanitize(started_at),
        "completed_at" => Serializer.sanitize(completed_at),
        "duration_us" => 2_530_865
      })

    assert step_execution.started_at == DateTime.to_iso8601(started_at)
    assert step_execution.completed_at == DateTime.to_iso8601(completed_at)
    assert step_execution.duration_us == 2_530_865
  end

  defp running_step_execution(execution_id, item_index) do
    %{
      id: "#{execution_id}:fan_out_step:#{item_index}:1",
      execution_id: execution_id,
      step_id: "fan_out_step",
      step_type_id: "fan_out",
      status: :running,
      attempt: 1,
      item_index: item_index,
      items_total: 2,
      started_at: ~U[2026-03-01 00:00:00Z],
      metadata: %{}
    }
  end
end
