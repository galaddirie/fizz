defmodule Fizz.Workspaces.Workers.ReconcileStaleJobsWorker do
  @moduledoc """
  Marks stale running jobs as system_error.
  """

  use Oban.Worker, queue: :workspaces_maintenance, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    count = Fizz.Workspaces.recover_stale_jobs(180)
    Logger.info("workspaces stale reconcile completed", stale_jobs: count)
    :ok
  end
end
