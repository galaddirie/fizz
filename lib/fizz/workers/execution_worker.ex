defmodule Fizz.Workers.ExecutionWorker do
  @moduledoc """
  Oban worker for executing workflows through the Runtime Execution Supervisor.

  ## Role in Architecture

  This is the **job queue entry point** — a thin wrapper that handles async/background job concerns:

  - Receives Oban jobs from the queue
  - Receives Oban jobs from the queue
  - Starts or attaches to execution processes via `Fizz.Runtime.Execution.Supervisor`
  - Monitors execution processes and waits for completion
  - Returns Oban-compatible results (:ok, {:error, ...})

  ## Configuration

  - Queue: `:executions`
  - Max attempts: 1 (failures are terminal, no automatic retries)
  - Unique: prevents duplicate jobs for same execution within 60 seconds
  """

  use Oban.Worker,
    queue: :executions,
    max_attempts: 1,
    unique: [period: 60, keys: [:execution_id]]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    execution_id = Map.fetch!(args, "execution_id")

    Logger.metadata(execution_id: execution_id)
    Logger.info("Starting workflow execution job")

    # If this was a scheduled trigger, schedule the next one
    maybe_schedule_next(execution_id)

    # Start the execution process (or attach to existing)
    case Fizz.Runtime.Execution.Supervisor.start_execution(execution_id) do
      {:ok, pid} ->
        monitor_and_wait(pid, execution_id)

      {:error, {:already_started, pid}} ->
        Logger.info("Execution already running, attaching", execution_id: execution_id)
        monitor_and_wait(pid, execution_id)

      {:error, reason} ->
        Logger.error("Failed to start execution process",
          execution_id: execution_id,
          reason: inspect(reason)
        )

        # Will retry if max_attempts > 1, but configured to 1
        {:error, reason}
    end
  end

  @doc false
  def maybe_schedule_next(execution_id) do
    execution =
      Fizz.Repo.get(Fizz.Executions.Execution, execution_id)
      |> Fizz.Repo.preload(workflow: :draft)

    case execution do
      %{trigger: %{type: :schedule}, status: :pending} ->
        schedule_next_run(execution)

      _ ->
        :ok
    end
  end

  @doc false
  def schedule_next_run(execution) do
    # Look for interval or cron in trigger config
    config = execution.trigger.data || %{}
    interval_sec = Map.get(config, "interval_seconds") || Map.get(config, "interval")

    if interval_sec do
      next_run = DateTime.add(DateTime.utc_now(), interval_sec, :second)

      Logger.info(
        "Scheduling next execution for workflow #{execution.workflow_id} in #{interval_sec}s"
      )

      # Create a NEW execution for the next run
      # The trigger info should be preserved
      attrs = %{
        workflow_id: execution.workflow_id,
        execution_type: execution.execution_type,
        trigger: %{
          "type" => "schedule",
          "data" => config
        }
      }

      case Fizz.Executions.create_execution(nil, attrs) do
        {:ok, next_execution} ->
          enqueue(next_execution.id, scheduled_at: next_run)

        {:error, reason} ->
          Logger.error("Failed to schedule next execution: #{inspect(reason)}")
      end
    else
      Logger.warning("Schedule trigger found but no interval/cron configured",
        execution_id: execution.id
      )
    end
  end

  @doc """
  Runs an execution synchronously and waits for it to finish.
  """
  def run_sync(execution_id) do
    case Fizz.Runtime.Execution.Supervisor.start_execution(execution_id) do
      {:ok, pid} ->
        monitor_and_wait(pid, execution_id)

      {:error, {:already_started, pid}} ->
        monitor_and_wait(pid, execution_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp monitor_and_wait(pid, execution_id) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _pid, :normal} ->
        # Execution completed explicitly (Server stops with :normal on finish)
        Logger.info("Execution process finished normally", execution_id: execution_id)
        :ok

      {:DOWN, ^ref, :process, _pid, :shutdown} ->
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        Logger.error("Execution process crashed or failed",
          execution_id: execution_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # ============================================================================
  # Job Creation Helpers
  # ============================================================================

  @doc """
  Creates job args for an execution.

  Includes trace context propagation for distributed tracing.
  """
  def build_args(execution_id, opts \\ []) do
    args = %{
      "execution_id" => execution_id
    }

    # Add any additional metadata
    case Keyword.get(opts, :metadata) do
      nil -> args
      metadata when is_map(metadata) -> Map.merge(args, metadata)
    end
  end

  @doc """
  Creates a new Oban job for the given execution.

  Returns `{:ok, job}` or `{:error, changeset}`.

  ## Options

  - `:scheduled_at` - Schedule the job for a future time
  - `:priority` - Job priority (0-3, lower is higher priority)
  - `:metadata` - Additional metadata to include in job args
  """
  def new_job(execution_id, opts \\ []) do
    args = build_args(execution_id, opts)

    job_opts =
      opts
      |> Keyword.take([:scheduled_at, :priority])
      |> Keyword.put_new(:priority, 1)

    __MODULE__.new(args, job_opts)
  end

  @doc """
  Inserts a job for the given execution.

  Returns `{:ok, job}` or `{:error, changeset}`.
  """
  def enqueue(execution_id, opts \\ []) do
    execution_id
    |> new_job(opts)
    |> Oban.insert()
  end
end
