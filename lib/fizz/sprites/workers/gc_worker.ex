defmodule Fizz.Sprites.Workers.GCWorker do
  @moduledoc """
  Garbage-collects old usage/log/checkpoint/rate-limit artifacts.
  """

  use Oban.Worker, queue: :sprites_maintenance, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    :ok = Fizz.Sprites.gc()
    :ok
  end
end
