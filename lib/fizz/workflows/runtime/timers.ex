defmodule Fizz.Workflows.Runtime.Timers do
  @moduledoc false

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Workflows.Runtime.DurableRows
  alias Fizz.Workflows.{DurableTimer, WorkflowRun}

  def create_timer(run_id, step_id, fire_at, opts \\ [])

  def create_timer(run_id, step_id, %DateTime{} = fire_at, opts)
      when is_binary(run_id) and is_binary(step_id) and is_list(opts) do
    with {:ok, run} <- fetch_run(run_id) do
      attrs = %{
        run_id: run.id,
        step_id: step_id,
        timer_name: Keyword.get(opts, :timer_name, step_id),
        project_id: run.project_id,
        workos_organization_id: run.workos_organization_id,
        fire_at: fire_at,
        status: :pending,
        payload: Keyword.get(opts, :payload)
      }

      %DurableTimer{}
      |> DurableTimer.changeset(attrs)
      |> Repo.insert()
    end
  end

  def claim_due_timers(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 50)
    claim_opts = opts |> Keyword.put(:now, now) |> Keyword.put(:limit, limit)

    DurableTimer
    |> where([timer], timer.status == :pending and timer.fire_at <= ^now)
    |> order_by([timer], asc: timer.fire_at)
    |> DurableRows.claim_many(&DurableTimer.changeset/2, :firing, claim_opts)
  end

  def claim_timer(timer_id, opts \\ []) when is_binary(timer_id) do
    DurableRows.claim_one(
      DurableTimer,
      timer_id,
      &DurableTimer.changeset/2,
      :firing,
      :for_update,
      opts
    )
  end

  def recover_stale_timers(opts \\ []) do
    DurableRows.recover_stale(DurableTimer, :firing, opts)
  end

  def release_timer_claim(timer_id) when is_binary(timer_id) do
    DurableRows.release_claim(DurableTimer, timer_id, :firing)
  end

  def get_timer(timer_id) when is_binary(timer_id) do
    DurableRows.get(DurableTimer, timer_id)
  end

  def mark_timer_fired(timer_id) when is_binary(timer_id) do
    case DurableRows.update_matching(DurableTimer, timer_id, [:firing], status: :fired) do
      :ok ->
        :ok

      {:error, :not_found} ->
        case Repo.get(DurableTimer, timer_id) do
          %DurableTimer{status: :fired} -> :ok
          _ -> {:error, :not_found}
        end
    end
  end

  def run_has_pending_timers?(run_id) when is_binary(run_id) do
    DurableTimer
    |> where([timer], timer.run_id == ^run_id and timer.status in ^[:pending, :firing])
    |> Repo.exists?()
  end

  def cancel_pending_timers(run_id) when is_binary(run_id) do
    now = DateTime.utc_now()

    _ =
      DurableTimer
      |> where([timer], timer.run_id == ^run_id and timer.status == :pending)
      |> Repo.update_all(set: [status: :cancelled, updated_at: now])

    :ok
  end

  defp fetch_run(run_id) when is_binary(run_id) do
    case Repo.get(WorkflowRun, run_id) do
      %WorkflowRun{} = run -> {:ok, run}
      nil -> {:error, :run_not_found}
    end
  end
end
