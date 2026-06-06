defmodule Fizz.Triggers do
  @moduledoc """
  Context for trigger registrations, caches, and event bookkeeping.
  """

  import Ecto.Query

  alias Fizz.Accounts.Scope
  alias Fizz.Repo
  alias Fizz.Workflows.StepExecutor, as: StepExecutorBehaviour
  alias Fizz.Triggers.{TriggerEvent, TriggerRegistration, TriggerSource, TriggerSourceRow}
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @notification_channel "trigger_registrations"
  @terminal_event_statuses ~w(fired skipped failed)
  @source_notification_channel "trigger_sources"

  @spec get_source!(String.t()) :: TriggerSource.t()
  def get_source!(id) when is_binary(id), do: Repo.get!(TriggerSource, id)

  @spec get_source(String.t()) :: TriggerSource.t() | nil
  def get_source(id) when is_binary(id), do: Repo.get(TriggerSource, id)

  @spec list_active_sources(keyword()) :: [TriggerSource.t()]
  def list_active_sources(opts \\ []) do
    TriggerSource
    |> where([source], source.status == "active")
    |> maybe_filter_source_kind(Keyword.get(opts, :kind))
    |> order_by([source], asc: source.inserted_at)
    |> Repo.all()
  end

  @spec upsert_source(map()) :: {:ok, TriggerSource.t()} | {:error, Ecto.Changeset.t()}
  def upsert_source(attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      attrs
      |> source_key()
      |> existing_source()
      |> case do
        nil ->
          %TriggerSource{}
          |> TriggerSource.changeset(attrs)
          |> Repo.insert()

        %TriggerSource{} = source ->
          source
          |> TriggerSource.changeset(preserve_source_runtime_fields(source, attrs))
          |> Repo.update()
      end
      |> case do
        {:ok, source} -> source
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, source} ->
        notify_source_registry("upsert", source.id)
        {:ok, source}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  @spec begin_event_pending(String.t(), String.t(), map()) ::
          {:ok, TriggerEvent.t()} | {:error, :duplicate, TriggerEvent.t()} | {:error, term()}
  def begin_event_pending(registration_id, event_id, event_data)
      when is_binary(registration_id) and is_binary(event_id) and is_map(event_data) do
    registration = get_registration!(registration_id)

    attrs = %{
      trigger_registration_id: registration.id,
      project_id: registration.project_id,
      workos_organization_id: registration.workos_organization_id,
      event_id: event_id,
      event_data: event_data,
      status: "pending"
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

  @spec list_registrations_for_source(String.t()) :: [TriggerRegistration.t()]
  def list_registrations_for_source(source_id) when is_binary(source_id) do
    TriggerRegistration
    |> where(
      [registration],
      registration.trigger_source_id == ^source_id and registration.status == "active"
    )
    |> order_by([registration], asc: registration.inserted_at)
    |> Repo.all()
  end

  @spec claim_source_for_poll(String.t(), String.t(), non_neg_integer(), DateTime.t()) ::
          :ok | {:error, :busy}
  def claim_source_for_poll(source_id, lease_owner, lease_ttl_ms, now \\ DateTime.utc_now())
      when is_binary(source_id) and is_binary(lease_owner) and is_integer(lease_ttl_ms) do
    lease_expires_at = DateTime.add(now, lease_ttl_ms, :millisecond)

    {count, _rows} =
      TriggerSource
      |> where(
        [source],
        source.id == ^source_id and source.status == "active" and
          (is_nil(source.lease_expires_at) or source.lease_expires_at <= ^now or
             source.lease_owner == ^lease_owner)
      )
      |> Repo.update_all(
        set: [
          lease_owner: lease_owner,
          lease_expires_at: lease_expires_at,
          updated_at: now
        ]
      )

    case count do
      1 -> :ok
      _ -> {:error, :busy}
    end
  end

  @spec record_source_poll_success(TriggerSource.t(), map() | nil, DateTime.t()) ::
          {:ok, TriggerSource.t()} | {:error, Ecto.Changeset.t()}
  def record_source_poll_success(%TriggerSource{} = source, cursor, now \\ DateTime.utc_now()) do
    next_poll_at = DateTime.add(now, source.poll_interval_ms, :millisecond)

    source
    |> TriggerSource.changeset(%{
      cursor: cursor,
      last_polled_at: now,
      next_poll_at: next_poll_at,
      backoff_until: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      error_message: nil,
      consecutive_errors: 0,
      last_error_at: nil
    })
    |> force_clear_source_lease()
    |> Repo.update()
  end

  @spec record_source_poll_error(TriggerSource.t(), term(), keyword()) ::
          {:ok, TriggerSource.t()} | {:error, Ecto.Changeset.t()}
  def record_source_poll_error(%TriggerSource{} = source, reason, opts \\ []) do
    now = DateTime.utc_now()
    backoff_ms = Keyword.get(opts, :backoff_ms, source_backoff_ms(source.consecutive_errors + 1))
    backoff_until = DateTime.add(now, backoff_ms, :millisecond)

    source
    |> TriggerSource.changeset(%{
      backoff_until: backoff_until,
      next_poll_at: backoff_until,
      lease_owner: nil,
      lease_expires_at: nil,
      error_message: source_error_message(reason),
      consecutive_errors: source.consecutive_errors + 1,
      last_error_at: now
    })
    |> force_clear_source_lease()
    |> Repo.update()
  end

  @spec list_source_rows(String.t()) :: [TriggerSourceRow.t()]
  def list_source_rows(source_id) when is_binary(source_id) do
    TriggerSourceRow
    |> where([row], row.trigger_source_id == ^source_id)
    |> order_by([row], asc: row.row_number)
    |> Repo.all()
  end

  @spec upsert_source_rows(String.t(), [map()]) :: :ok | {:error, term()}
  def upsert_source_rows(source_id, rows) when is_binary(source_id) and is_list(rows) do
    Repo.transaction(fn ->
      Enum.each(rows, fn attrs ->
        attrs = Map.put(attrs, :trigger_source_id, source_id)

        case Repo.insert(
               TriggerSourceRow.changeset(%TriggerSourceRow{}, attrs),
               on_conflict: [
                 set: [
                   row_number: attrs.row_number,
                   row_hash: attrs.row_hash,
                   values: attrs.values,
                   raw_values: attrs.raw_values,
                   last_seen_at: attrs.last_seen_at,
                   last_changed_at: attrs.last_changed_at,
                   updated_at: DateTime.utc_now()
                 ]
               ],
               conflict_target: [:trigger_source_id, :row_key]
             ) do
          {:ok, _row} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec replace_source_rows(String.t(), [map()]) :: :ok | {:error, term()}
  def replace_source_rows(source_id, rows) when is_binary(source_id) and is_list(rows) do
    row_keys = Enum.map(rows, & &1.row_key)

    Repo.transaction(fn ->
      case upsert_source_rows(source_id, rows) do
        :ok -> prune_missing_source_rows(source_id, row_keys)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
         step_id: step_id,
         user_id: user_id
       })
       when is_binary(definition_version_id) and is_binary(step_id) and is_binary(user_id) do
    TriggerRegistration
    |> where(
      [registration],
      registration.definition_version_id == ^definition_version_id and
        registration.step_id == ^step_id and registration.user_id == ^user_id and
        is_nil(registration.run_id)
    )
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

  defp source_key(%{source_key: source_key}) when is_binary(source_key), do: source_key
  defp source_key(%{"source_key" => source_key}) when is_binary(source_key), do: source_key
  defp source_key(_attrs), do: nil

  defp existing_source(source_key) when is_binary(source_key) do
    Repo.get_by(TriggerSource, source_key: source_key)
  end

  defp existing_source(_source_key), do: nil

  defp preserve_source_runtime_fields(%TriggerSource{} = source, attrs) do
    attrs
    |> Map.put(:cursor, source.cursor)
    |> Map.put(:last_polled_at, source.last_polled_at)
    |> Map.put(:next_poll_at, source.next_poll_at)
  end

  defp prune_missing_source_rows(source_id, []) do
    TriggerSourceRow
    |> where([row], row.trigger_source_id == ^source_id)
    |> Repo.delete_all()

    :ok
  end

  defp prune_missing_source_rows(source_id, row_keys) do
    TriggerSourceRow
    |> where([row], row.trigger_source_id == ^source_id and row.row_key not in ^row_keys)
    |> Repo.delete_all()

    :ok
  end

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

  defp maybe_filter_source_kind(query, nil), do: query

  defp maybe_filter_source_kind(query, kind) when is_atom(kind) do
    maybe_filter_source_kind(query, Atom.to_string(kind))
  end

  defp maybe_filter_source_kind(query, kind) when is_binary(kind) do
    where(query, [source], source.kind == ^kind)
  end

  defp maybe_filter_source_kind(query, _kind), do: query

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

  defp notify_source_registry(event, source_id) do
    payload = Jason.encode!(%{"event" => event, "source_id" => source_id})

    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT pg_notify($1, $2)",
           [@source_notification_channel, payload]
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp source_backoff_ms(error_count) when error_count <= 1, do: :timer.seconds(15)
  defp source_backoff_ms(error_count) when error_count <= 3, do: :timer.minutes(1)
  defp source_backoff_ms(error_count) when error_count <= 6, do: :timer.minutes(5)
  defp source_backoff_ms(_error_count), do: :timer.minutes(15)

  defp source_error_message(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> String.slice(0, 255)
  end

  defp force_clear_source_lease(changeset) do
    changeset
    |> Ecto.Changeset.force_change(:lease_owner, nil)
    |> Ecto.Changeset.force_change(:lease_expires_at, nil)
  end
end
