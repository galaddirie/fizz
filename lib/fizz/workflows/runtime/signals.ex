defmodule Fizz.Workflows.Runtime.Signals do
  @moduledoc false

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Workflows.Runtime.DurableRows
  alias Fizz.Workflows.Runtime.Payloads
  alias Fizz.Workflows.{SignalInbox, WorkflowRun}

  def create_signal_inbox(run_id, signal_id, signal_name, payload)
      when is_binary(run_id) and is_binary(signal_id) and is_binary(signal_name) do
    with {:ok, run} <- fetch_run(run_id) do
      attrs = %{
        run_id: run.id,
        signal_id: signal_id,
        signal_name: signal_name,
        payload: Payloads.normalize(payload) || %{},
        status: :pending,
        project_id: run.project_id,
        workos_organization_id: run.workos_organization_id
      }

      %SignalInbox{}
      |> SignalInbox.changeset(attrs)
      |> Repo.insert(
        on_conflict: [set: [signal_id: signal_id]],
        conflict_target: [:run_id, :signal_id],
        returning: true
      )
    end
  end

  def claim_pending_signals(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 50)
    claim_opts = opts |> Keyword.put(:now, now) |> Keyword.put(:limit, limit)

    SignalInbox
    |> where([signal], signal.status == :pending)
    |> order_by([signal], asc: signal.inserted_at)
    |> DurableRows.claim_many(&SignalInbox.changeset/2, :delivering, claim_opts)
  end

  def claim_signal(signal_id, opts \\ []) when is_binary(signal_id) do
    DurableRows.claim_one(
      SignalInbox,
      signal_id,
      &SignalInbox.changeset/2,
      :delivering,
      :for_update_skip_locked,
      opts
    )
  end

  def recover_stale_signals(opts \\ []) do
    DurableRows.recover_stale(SignalInbox, :delivering, opts)
  end

  def release_signal_claim(signal_id) when is_binary(signal_id) do
    DurableRows.release_claim(SignalInbox, signal_id, :delivering)
  end

  def get_signal(signal_id) when is_binary(signal_id) do
    DurableRows.get(SignalInbox, signal_id)
  end

  def mark_signal_delivered(signal_id) when is_binary(signal_id) do
    now = DateTime.utc_now()

    DurableRows.update_matching(SignalInbox, signal_id, [:pending, :delivering],
      status: :delivered,
      delivered_at: now,
      claimed_at: nil,
      claimed_by: nil,
      updated_at: now
    )
  end

  def mark_signal_skipped(signal_id) when is_binary(signal_id) do
    now = DateTime.utc_now()

    DurableRows.update_matching(SignalInbox, signal_id, [:pending, :delivering],
      status: :skipped,
      delivered_at: now,
      claimed_at: nil,
      claimed_by: nil,
      updated_at: now
    )
  end

  defp fetch_run(run_id) when is_binary(run_id) do
    case Repo.get(WorkflowRun, run_id) do
      %WorkflowRun{} = run -> {:ok, run}
      nil -> {:error, :run_not_found}
    end
  end
end
