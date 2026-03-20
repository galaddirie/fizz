defmodule Fizz.Triggers.Workers.TriggerFireWorker do
  @moduledoc """
  Bridges normalized trigger events into new workflow runs or run-level signals.
  """

  use Oban.Worker,
    queue: :triggers,
    max_attempts: 5,
    unique: [keys: [:trigger_registration_id, :event_id], period: 300]

  alias Fizz.Accounts.Project
  alias Fizz.Accounts.Scope
  alias Fizz.Triggers
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Workflows

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "trigger_registration_id" => trigger_registration_id,
          "event_id" => event_id,
          "normalized_data" => normalized_data
        }
      }) do
    registration = Triggers.get_registration!(trigger_registration_id)

    with {:ok, _event} <- begin_event(registration, event_id, normalized_data),
         {:ok, result} <- route_event(registration, event_id, normalized_data) do
      :ok =
        result
        |> event_status_attrs()
        |> then(fn opts ->
          case Triggers.record_event(
                 registration.id,
                 event_id,
                 normalized_data,
                 "fired",
                 opts
               ) do
            {:ok, _event} -> :ok
            {:error, _reason} -> :ok
          end
        end)

      :ok
    else
      {:duplicate, _event} ->
        :ok

      {:ok, :skipped} ->
        case Triggers.record_event(registration.id, event_id, normalized_data, "skipped") do
          {:ok, _event} -> :ok
          {:error, _reason} -> :ok
        end

        :ok

      {:error, reason} ->
        _ = Triggers.record_event(registration.id, event_id, normalized_data, "failed")
        {:error, inspect(reason)}
    end
  end

  defp begin_event(%TriggerRegistration{} = registration, event_id, normalized_data) do
    case Triggers.begin_event_processing(registration.id, event_id, normalized_data) do
      {:ok, event} ->
        {:ok, event}

      {:error, :duplicate, existing_event} ->
        if existing_event.status in ["fired", "skipped", "processing"] do
          {:duplicate, existing_event}
        else
          {:ok, existing_event}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_event(%TriggerRegistration{status: status}, _event_id, _normalized_data)
       when status != "active" do
    {:ok, :skipped}
  end

  defp route_event(%TriggerRegistration{run_id: nil} = registration, event_id, normalized_data) do
    metadata = triggered_by_metadata(registration, event_id)

    registration
    |> project_scope()
    |> then(
      &Workflows.start_run(&1, registration.definition_version_id, normalized_data,
        triggered_by: metadata
      )
    )
    |> case do
      {:ok, run} -> {:ok, {:run, run.id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp route_event(%TriggerRegistration{run_id: run_id} = registration, event_id, normalized_data) do
    registration
    |> project_scope()
    |> then(&Workflows.signal_run(&1, run_id, registration.step_id, normalized_data, event_id))
    |> case do
      {:ok, _signal} -> {:ok, {:signal, run_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp triggered_by_metadata(registration, event_id) do
    %{
      "trigger_registration_id" => registration.id,
      "trigger_step_id" => registration.step_id,
      "trigger_kind" => registration.kind,
      "event_id" => event_id,
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp project_scope(%TriggerRegistration{} = registration) do
    %Scope{
      organization_id: registration.workos_organization_id,
      project: %Project{
        id: registration.project_id,
        workos_organization_id: registration.workos_organization_id
      }
    }
  end

  defp event_status_attrs({:run, run_id}), do: [run_id: run_id]
  defp event_status_attrs({:signal, run_id}), do: [run_id: run_id]
end
