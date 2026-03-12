defmodule Fizz.Workspaces.Workers.ConsoleReaperWorker do
  @moduledoc """
  Reaps old active console leases.
  """

  use Oban.Worker, queue: :workspaces_maintenance, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    count = Fizz.Workspaces.reap_idle_consoles(300)
    Logger.info("workspaces console reaper completed", reaped: count)
    :ok
  end
end
