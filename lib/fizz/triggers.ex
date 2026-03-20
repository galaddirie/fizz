defmodule Fizz.Triggers do
  @moduledoc """
  Context for trigger registrations, caches, and event bookkeeping.
  """

  import Ecto.Query

  alias Fizz.Accounts.Scope
  alias Fizz.Repo
  alias Fizz.Steps.Executors.Behaviour, as: StepExecutorBehaviour
  alias Fizz.Triggers.{TriggerEvent, TriggerRegistration}
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @notification_channel "trigger_registrations"
  @terminal_event_statuses ~w(fired skipped failed)

  @spec get_registration!(String.t()) :: TriggerRegistration.t()
  def get_registration!(id) when is_binary(id) do
    Repo.get!(TriggerRegistration, id)
  end

  @spec list_registrations(Scope.t() | nil, keyword()) ::
          {:ok, [TriggerRegistration.t()]} | {:error, :project_scope_required}
  def list_registrations(scope, opts \\ [])

  def list_registrations(%Scope{project: %{id: project_id}}, opts) do
    registrations =
      TriggerRegistration
      |> where([registration], registration.project_id == ^project_id)
      |> maybe_filter_kind(Keyword.get(opts, :kind))
      |> maybe_filter_status(Keyword.get(opts, :status))
      |> maybe_filter_definition_id(Keyword.get(opts, :definition_id))
      |> order_by([registration], desc: registration.inserted_at)
      |> Repo.all()

    {:ok, registrations}
  end

  def list_registrations(_scope, _opts), do: {:error, :project_scope_required}

  @spec upsert_registration(map()) ::
          {:ok, TriggerRegistration.t()} | {:error, Ecto.Changeset.t() | term()}
  def upsert_registration(attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      attrs
      |> find_existing_registration()
      |> case do
        nil ->
          %TriggerRegistration{}
          |> TriggerRegistration.changeset(attrs)
          |> Repo.insert()

        %TriggerRegistration{} = registration ->
          registration
          |> TriggerRegistration.changeset(attrs)
          |> Repo.update()
      end
      |> case do
        {:ok, registration} -> registration
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, registration} ->
        notify_registry("upsert", registration.id)
        {:ok, registration}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec deactivate_registration(TriggerRegistration.t()) ::
          {:ok, TriggerRegistration.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_registration(%TriggerRegistration{} = registration) do
    registration
    |> TriggerRegistration.changeset(%{status: "inactive"})
    |> Repo.update()
    |> case do
      {:ok, updated_registration} ->
        notify_registry("deactivate", updated_registration.id)
        {:ok, updated_registration}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec begin_event_processing(String.t(), String.t(), map()) ::
          {:ok, TriggerEvent.t()} | {:error, :duplicate, TriggerEvent.t()} | {:error, term()}
  def begin_event_processing(registration_id, event_id, event_data)
      when is_binary(registration_id) and is_binary(event_id) and is_map(event_data) do
    registration = get_registration!(registration_id)

    attrs = %{
      trigger_registration_id: registration.id,
      project_id: registration.project_id,
      workos_organization_id: registration.workos_organization_id,
      event_id: event_id,
      event_data: event_data,
      status: "processing"
    }

    case Repo.insert(
           TriggerEvent.changeset(%TriggerEvent{}, attrs),
           on_conflict: :nothing,
           conflict_target: [:trigger_registration_id, :event_id],
           returning: true
         ) do
      {:ok, %TriggerEvent{id: nil}} ->
        existing =
          TriggerEvent
          |> where(
            [event],
            event.trigger_registration_id == ^registration.id and event.event_id == ^event_id
          )
          |> Repo.one!()

        {:error, :duplicate, existing}

      {:ok, event} ->
        {:ok, event}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec record_event(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, TriggerEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_event(registration_id, event_id, event_data, status, opts \\ [])
      when is_binary(registration_id) and is_binary(event_id) and is_map(event_data) and
             is_binary(status) do
    registration = get_registration!(registration_id)

    attrs = %{
      trigger_registration_id: registration.id,
      project_id: registration.project_id,
      workos_organization_id: registration.workos_organization_id,
      event_id: event_id,
      event_data: event_data,
      status: status,
      run_id: Keyword.get(opts, :run_id),
      processed_at: processed_at_for_status(status)
    }

    %TriggerEvent{}
    |> TriggerEvent.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          event_data: attrs.event_data,
          status: attrs.status,
          run_id: attrs.run_id,
          processed_at: attrs.processed_at
        ]
      ],
      conflict_target: [:trigger_registration_id, :event_id],
      returning: true
    )
  end

  @spec resolve_registration_executor(TriggerRegistration.t()) ::
          {:ok, module()} | {:error, term()}
  def resolve_registration_executor(%TriggerRegistration{} = registration) do
    with %WorkflowDefinitionVersion{} = version <-
           Repo.get(WorkflowDefinitionVersion, registration.definition_version_id),
         %{type_id: type_id} <- Enum.find(version.steps, &(&1.id == registration.step_id)),
         {:ok, executor} <- StepExecutorBehaviour.resolve(type_id) do
      {:ok, executor}
    else
      nil -> {:error, :definition_version_not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :trigger_step_not_found}
    end
  end

  @spec update_schedule_next_fire_at(TriggerRegistration.t(), DateTime.t()) ::
          {:ok, TriggerRegistration.t()} | {:error, Ecto.Changeset.t()}
  def update_schedule_next_fire_at(
        %TriggerRegistration{} = registration,
        %DateTime{} = next_fire_at
      ) do
    registration
    |> TriggerRegistration.changeset(%{next_fire_at: next_fire_at})
    |> Repo.update()
  end

  @spec mark_registration_errored(TriggerRegistration.t(), term()) ::
          {:ok, TriggerRegistration.t()} | {:error, Ecto.Changeset.t()}
  def mark_registration_errored(%TriggerRegistration{} = registration, reason) do
    registration
    |> TriggerRegistration.changeset(%{
      status: "errored",
      error_message: inspect(reason),
      consecutive_errors: registration.consecutive_errors + 1,
      last_error_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp find_existing_registration(%{run_id: run_id, step_id: step_id})
       when is_binary(run_id) and is_binary(step_id) do
    TriggerRegistration
    |> where([registration], registration.run_id == ^run_id and registration.step_id == ^step_id)
    |> Repo.one()
  end

  defp find_existing_registration(%{
         definition_version_id: definition_version_id,
         step_id: step_id
       })
       when is_binary(definition_version_id) and is_binary(step_id) do
    TriggerRegistration
    |> where(
      [registration],
      registration.definition_version_id == ^definition_version_id and
        registration.step_id == ^step_id and is_nil(registration.run_id)
    )
    |> Repo.one()
  end

  defp find_existing_registration(_attrs), do: nil

  defp maybe_filter_kind(query, nil), do: query

  defp maybe_filter_kind(query, kind) when is_atom(kind) do
    maybe_filter_kind(query, Atom.to_string(kind))
  end

  defp maybe_filter_kind(query, kind) when is_binary(kind) do
    where(query, [registration], registration.kind == ^kind)
  end

  defp maybe_filter_kind(query, _kind), do: query

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, statuses) do
    statuses =
      statuses
      |> List.wrap()
      |> Enum.map(fn
        status when is_atom(status) -> Atom.to_string(status)
        status when is_binary(status) -> status
      end)

    where(query, [registration], registration.status in ^statuses)
  end

  defp maybe_filter_definition_id(query, nil), do: query

  defp maybe_filter_definition_id(query, definition_id) when is_binary(definition_id) do
    where(query, [registration], registration.workflow_definition_id == ^definition_id)
  end

  defp maybe_filter_definition_id(query, _definition_id), do: query

  defp processed_at_for_status(status) when status in @terminal_event_statuses,
    do: DateTime.utc_now()

  defp processed_at_for_status(_status), do: nil

  defp notify_registry(event, registration_id) do
    payload = Jason.encode!(%{"event" => event, "registration_id" => registration_id})

    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT pg_notify($1, $2)",
           [@notification_channel, payload]
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end
end
