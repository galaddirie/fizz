defmodule Fizz.Sprites.ReconciliationWorker do
  @moduledoc """
  Periodic job that reconciles active local sprite sessions with provider sessions.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  require Logger

  alias Fizz.Sprites

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Sprites.reconcile_sessions() do
      {:ok, summary} ->
        Logger.info("sprites.reconciliation.completed #{inspect(summary)}")
        :ok

      other ->
        Logger.error("sprites.reconciliation.unexpected_result result=#{inspect(other)}")
        {:error, inspect(other)}
    end
  end
end
