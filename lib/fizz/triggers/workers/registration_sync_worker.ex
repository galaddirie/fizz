defmodule Fizz.Triggers.Workers.RegistrationSyncWorker do
  @moduledoc """
  Periodically reconciles durable trigger registrations and event retention.
  """

  use Oban.Worker, queue: :triggers, max_attempts: 1

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Triggers
  alias Fizz.Triggers.RegistrationManager
  alias Fizz.Triggers.TriggerEvent
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Triggers.Workers.TriggerFireWorker
  alias Fizz.Workflows.WorkflowDefinition
  alias Fizz.Workflows.WorkflowDefinitionVersion

  require Logger

  @cooldown_minutes 5
  @event_retention_days 7

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    sync_published_versions()
    deactivate_unpublished_registrations()
    reset_errored_registrations()
    recover_broken_schedule_chains()
    prune_terminal_events()
    :ok
  end

  defp sync_published_versions do
    WorkflowDefinitionVersion
    |> join(:inner, [version], definition in WorkflowDefinition,
      on: definition.id == version.workflow_definition_id
    )
    |> where(
      [version, definition],
      version.status == :published and is_nil(definition.archived_at)
    )
    |> order_by([version],
      asc: version.workflow_definition_id,
      desc: version.published_at,
      desc: version.inserted_at
    )
    |> select([version], version)
    |> Repo.all()
    |> Enum.uniq_by(& &1.workflow_definition_id)
    |> Enum.each(fn version ->
      case RegistrationManager.sync_on_publish(version) do
        :ok ->
          :ok

        {:error, errors} ->
          Logger.warning("trigger registration sync had errors: #{inspect(errors)}")
      end
    end)
  end

  defp deactivate_unpublished_registrations do
    now = DateTime.utc_now()

    registration_ids =
      TriggerRegistration
      |> join(:left, [registration], version in WorkflowDefinitionVersion,
        on: version.id == registration.definition_version_id
      )
      |> join(:left, [registration, version], definition in WorkflowDefinition,
        on: definition.id == registration.workflow_definition_id
      )
      |> where(
        [registration, version, definition],
        is_nil(registration.run_id) and registration.status != "inactive" and
          (is_nil(version.id) or version.status != :published or
             not is_nil(definition.archived_at))
      )
      |> select([registration], registration.id)
      |> Repo.all()

    case registration_ids do
      [] ->
        0

      ids ->
        {count, _rows} =
          TriggerRegistration
          |> where([registration], registration.id in ^ids)
          |> Repo.update_all(set: [status: "inactive", updated_at: now])

        count
    end
  end

  defp reset_errored_registrations do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@cooldown_minutes, :minute)

    {count, _rows} =
      TriggerRegistration
      |> where(
        [registration],
        registration.status == "errored" and
          not is_nil(registration.last_error_at) and registration.last_error_at <= ^cutoff
      )
      |> Repo.update_all(
        set: [
          status: "active",
          error_message: nil,
          consecutive_errors: 0,
          last_error_at: nil,
          updated_at: now
        ]
      )

    count
  end

  defp recover_broken_schedule_chains do
    now = DateTime.utc_now()

    overdue_registrations =
      TriggerRegistration
      |> where(
        [registration],
        registration.kind == "schedule" and registration.status == "active" and
          not is_nil(registration.next_fire_at) and registration.next_fire_at <= ^now
      )
      |> Repo.all()

    Enum.each(overdue_registrations, fn registration ->
      pending_job_exists? =
        Oban.Job
        |> where(
          [job],
          job.worker == "Fizz.Triggers.Workers.TriggerFireWorker" and
            job.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("?->>'trigger_registration_id' = ?", job.args, ^registration.id)
        )
        |> Repo.exists?()

      unless pending_job_exists? do
        event_id = "sched_#{registration.id}_#{DateTime.to_unix(now)}"

        normalized_data =
          case Triggers.resolve_registration_executor(registration) do
            {:ok, executor} ->
              case executor.normalize_event(registration.registration_params, %{}) do
                {:ok, data} -> Map.put(data, "scheduled_at", DateTime.to_iso8601(now))
                {:error, _} -> %{"scheduled_at" => DateTime.to_iso8601(now)}
              end

            {:error, _} ->
              %{"scheduled_at" => DateTime.to_iso8601(now)}
          end

        %{
          "trigger_registration_id" => registration.id,
          "event_id" => event_id,
          "normalized_data" => normalized_data
        }
        |> TriggerFireWorker.new()
        |> Oban.insert()

        Logger.info("recovered broken schedule chain for registration #{registration.id}")
      end
    end)
  end

  defp prune_terminal_events do
    cutoff = DateTime.add(DateTime.utc_now(), -@event_retention_days, :day)

    {count, _rows} =
      TriggerEvent
      |> where(
        [event],
        event.status in ["fired", "skipped", "failed"] and event.created_at < ^cutoff
      )
      |> Repo.delete_all()

    count
  end
end
