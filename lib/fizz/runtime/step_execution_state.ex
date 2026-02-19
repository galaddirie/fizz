defmodule Fizz.Runtime.StepExecutionState do
  @moduledoc """
  Unified state management for step executions.
  Ensures consistent serialization for both persistence and broadcasting.
  """

  alias Fizz.Runtime.Serializer

  def build(execution_id, step_id, status, opts \\ []) do
    %{
      execution_id: execution_id,
      step_id: step_id,
      status: status,
      input_data: opts[:input_data] |> Serializer.wrap_for_db(),
      output_data: opts[:output_data] |> Serializer.wrap_for_db(),
      output_item_count: opts[:output_item_count],
      item_index: opts[:item_index],
      items_total: opts[:items_total],
      error: opts[:error],
      step_type_id: opts[:step_type_id],
      duration_us: opts[:duration_us],
      started_at: opts[:started_at],
      completed_at: opts[:completed_at],
      metadata: opts[:metadata] || %{}
    }
  end

  def started(execution_id, step_id, input_data, opts \\ []) do
    build(execution_id, step_id, :running,
      input_data: input_data,
      step_type_id: opts[:step_type_id],
      item_index: opts[:item_index],
      items_total: opts[:items_total],
      started_at: opts[:started_at] || DateTime.utc_now()
    )
  end

  def completed(execution_id, step_id, input_data, output_data, opts \\ []) do
    build(execution_id, step_id, :completed,
      input_data: input_data,
      output_data: output_data,
      output_item_count: opts[:output_item_count],
      item_index: opts[:item_index],
      items_total: opts[:items_total],
      step_type_id: opts[:step_type_id],
      duration_us: opts[:duration_us],
      started_at: opts[:started_at],
      completed_at: opts[:completed_at] || DateTime.utc_now()
    )
  end

  def skipped(execution_id, step_id, input_data, opts \\ []) do
    build(execution_id, step_id, :skipped,
      input_data: input_data,
      step_type_id: opts[:step_type_id],
      item_index: opts[:item_index],
      items_total: opts[:items_total],
      duration_us: opts[:duration_us],
      started_at: opts[:started_at],
      completed_at: opts[:completed_at] || DateTime.utc_now()
    )
  end

  def failed(execution_id, step_id, input_data, error, opts \\ []) do
    build(execution_id, step_id, :failed,
      input_data: input_data,
      error: error,
      step_type_id: opts[:step_type_id],
      item_index: opts[:item_index],
      items_total: opts[:items_total],
      duration_us: opts[:duration_us],
      started_at: opts[:started_at],
      completed_at: opts[:completed_at] || DateTime.utc_now()
    )
  end
end
