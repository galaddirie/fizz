defmodule Fizz.Runtime.Triggers.ScheduleManager do
  @moduledoc """
  Manages scheduled trigger jobs via Oban.
  """
  require Logger
  alias Fizz.Workers.ScheduledTriggerWorker

  @doc """
  Activates scheduling for a workflow.
  Ensures there is exactly one pending job for the workflow's schedule.
  """
  def activate(workflow_id, config) do
    interval = Map.get(config, "interval_seconds") || Map.get(config, :interval_seconds)

    if interval do
      Logger.info("Activating schedule for workflow #{workflow_id} with interval #{interval}s")
      # Cancel existing to avoid duplicates if re-activated
      deactivate(workflow_id)

      # Create initial job
      # We schedule it for now, unless configured otherwise
      ScheduledTriggerWorker.enqueue(workflow_id, config)
    else
      Logger.warning("Schedule trigger for workflow #{workflow_id} missing interval_seconds")
    end
  end

  @doc """
  Deactivates scheduling by cancelling pending jobs.
  """
  def deactivate(workflow_id) do
    import Ecto.Query

    # Cancel all pending/scheduled jobs for this workflow
    Oban.Job
    |> where(worker: ^to_string(ScheduledTriggerWorker))
    |> where([j], fragment("args->>'workflow_id' = ?", ^workflow_id))
    |> where([j], j.state in ["available", "scheduled", "retryable"])
    |> Oban.cancel_all_jobs()
  end
end
