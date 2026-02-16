defmodule Fizz.Sprites.Workers.ReconcileStaleJobsWorker do
  @moduledoc """
  Marks stale running jobs as system_error.
  """

  use Oban.Worker, queue: :sprites_maintenance, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    count = Fizz.Sprites.reconcile_stale_jobs(180)
    Logger.info("sprites stale reconcile completed", stale_jobs: count)
    :ok
  end
end
