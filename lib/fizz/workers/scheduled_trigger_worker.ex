defmodule Fizz.Workers.ScheduledTriggerWorker do
  @moduledoc """
  Oban worker that triggers a workflow execution on a schedule.
  """
  use Oban.Worker, queue: :executions, max_attempts: 1

  require Logger
  alias Fizz.Executions
  alias Fizz.Workers.ExecutionWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workflow_id" => workflow_id, "config" => config}}) do
    Logger.info("Executing scheduled trigger for workflow: #{workflow_id}")

    attrs = %{
      workflow_id: workflow_id,
      execution_type: :production,
      trigger: %{
        "type" => "schedule",
        "data" => config
      }
    }

    # Use a system scope or similar if needed, here passing nil for now
    case Executions.create_execution(nil, attrs) do
      {:ok, execution} ->
        # Enqueue the execution worker to actually run it
        ExecutionWorker.enqueue(execution.id)
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to create scheduled execution for #{workflow_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Enqueues a scheduled trigger job.
  """
  def enqueue(workflow_id, config) do
    %{workflow_id: workflow_id, config: config}
    |> new()
    |> Oban.insert()
  end
end
