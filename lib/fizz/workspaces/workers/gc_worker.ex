defmodule Fizz.Workspaces.Workers.GCWorker do
  @moduledoc """
  Garbage-collects old logs and checkpoints.
  """

  use Oban.Worker, queue: :workspaces_maintenance, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    :ok = Fizz.Workspaces.run_gc()
    :ok
  end
end
