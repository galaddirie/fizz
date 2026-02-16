defmodule Fizz.Sprites.Workers.ConsoleReaperWorker do
  @moduledoc """
  Reaps old active console leases.
  """

  use Oban.Worker, queue: :sprites_maintenance, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    count = Fizz.Sprites.reap_old_consoles(300)
    Logger.info("sprites console reaper completed", reaped: count)
    :ok
  end
end
