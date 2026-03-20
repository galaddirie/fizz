defmodule Fizz.Triggers.RegistrationManager do
  @moduledoc """
  Synchronizes durable trigger registrations from compiled workflow metadata.
  """

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Steps.Executors.Behaviour, as: StepExecutorBehaviour
  alias Fizz.Triggers
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.WorkflowDefinition
  alias Fizz.Workflows.WorkflowDefinitionVersion
  alias Oban.Cron.Expression

  require Logger

  @type sync_error :: %{step_id: String.t(), reason: term()}

  @spec sync_on_publish(WorkflowDefinitionVersion.t()) :: :ok | {:error, [sync_error()]}
  def sync_on_publish(%WorkflowDefinitionVersion{} = definition_version) do
    with {:ok, workflow, _compiled_hash} <- Compiler.compile(definition_version),
         {:ok, context} <- load_definition_context(definition_version) do
      errors =
        workflow.fizz_metadata
        |> Map.get(:trigger_manifest, [])
        |> Enum.reduce([], fn trigger, acc ->
          case sync_trigger(trigger, context) do
            :ok -> acc
            {:error, reason} -> [%{step_id: trigger.step_id, reason: reason} | acc]
          end
        end)
        |> Enum.reverse()

      _ = deactivate_stale_registrations(definition_version)

      case errors do
        [] -> :ok
        _ -> {:error, errors}
      end
    end
  end

  @spec deactivate_stale_registrations(WorkflowDefinitionVersion.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def deactivate_stale_registrations(%WorkflowDefinitionVersion{} = definition_version) do
    now = DateTime.utc_now()

    {count, _rows} =
      TriggerRegistration
      |> where(
        [registration],
        registration.workflow_definition_id == ^definition_version.workflow_definition_id and
          registration.definition_version_id != ^definition_version.id and
          is_nil(registration.run_id) and registration.status != "inactive"
      )
      |> Repo.update_all(set: [status: "inactive", updated_at: now])

    if count > 0 do
      notify_stale_registrations(definition_version.workflow_definition_id)
    end

    {:ok, count}
  end

  @spec next_fire_at(map(), DateTime.t()) :: DateTime.t() | nil
  def next_fire_at(params, from \\ DateTime.utc_now())

  def next_fire_at(%{"interval_seconds" => interval_seconds}, %DateTime{} = from)
      when is_integer(interval_seconds) and interval_seconds > 0 do
    DateTime.add(from, interval_seconds, :second)
  end

  def next_fire_at(%{"cron" => cron, "timezone" => timezone}, %DateTime{} = from)
      when is_binary(cron) and is_binary(timezone) do
    cron
    |> parse_cron()
    |> case do
      {:ok, expression} ->
        from
        |> DateTime.shift_zone!(timezone)
        |> then(&Expression.next_at(expression, &1))
        |> normalize_next_fire_at()

      :error ->
        nil
    end
  end

  def next_fire_at(%{"cron" => cron}, %DateTime{} = from) when is_binary(cron) do
    cron
    |> parse_cron()
    |> case do
      {:ok, expression} -> normalize_next_fire_at(Expression.next_at(expression, from))
      :error -> nil
    end
  end

  def next_fire_at(_params, _from), do: nil

  defp sync_trigger(trigger, context) do
    with {:ok, executor} <- StepExecutorBehaviour.resolve(trigger.type_id),
         {:ok, spec} <- executor.registration_spec(trigger.config, context),
         attrs <- registration_attrs(trigger, spec, context),
         {:ok, _registration} <- Triggers.upsert_registration(attrs) do
      :ok
    end
  end

  defp load_definition_context(%WorkflowDefinitionVersion{} = definition_version) do
    case Repo.one(
           from(version in WorkflowDefinitionVersion,
             join: definition in WorkflowDefinition,
             on: definition.id == version.workflow_definition_id,
             where: version.id == ^definition_version.id,
             select: %{
               workflow_definition_id: definition.id,
               definition_version_id: version.id,
               project_id: definition.project_id,
               workos_organization_id: definition.workos_organization_id
             }
           )
         ) do
      nil -> {:error, :version_not_found}
      context -> {:ok, context}
    end
  end

  defp registration_attrs(trigger, spec, context) do
    params = spec.params || %{}
    now = DateTime.utc_now()
    existing = existing_registration(context.definition_version_id, trigger.step_id)

    %{
      workflow_definition_id: context.workflow_definition_id,
      definition_version_id: context.definition_version_id,
      step_id: trigger.step_id,
      project_id: context.project_id,
      workos_organization_id: context.workos_organization_id,
      run_id: nil,
      kind: Atom.to_string(spec.kind),
      status: "active",
      registration_params: params,
      config_digest: digest_for(spec),
      webhook_path: webhook_path(existing, spec),
      webhook_secret: webhook_secret(existing, spec),
      cron_expression: cron_expression(spec, trigger.config),
      next_fire_at: schedule_next_fire_at(existing, spec, now),
      cursor: polling_cursor(spec),
      poll_interval_ms: polling_interval(spec),
      last_polled_at: existing && existing.last_polled_at,
      batch_size: batch_size(spec),
      error_message: nil,
      consecutive_errors: 0,
      last_error_at: nil
    }
  end

  defp existing_registration(definition_version_id, step_id) do
    TriggerRegistration
    |> where(
      [registration],
      registration.definition_version_id == ^definition_version_id and
        registration.step_id == ^step_id and is_nil(registration.run_id)
    )
    |> Repo.one()
  end

  defp digest_for(spec) do
    %{
      "kind" => spec.kind,
      "params" => spec.params,
      "dedup_key" => spec.dedup_key
    }
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp webhook_path(%TriggerRegistration{webhook_path: path}, %{kind: :webhook})
       when is_binary(path) and path != "",
       do: path

  defp webhook_path(_existing, %{kind: :webhook}) do
    "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp webhook_path(_existing, _spec), do: nil

  defp webhook_secret(%TriggerRegistration{webhook_secret: secret}, %{kind: :webhook})
       when is_binary(secret) and secret != "",
       do: secret

  defp webhook_secret(_existing, %{kind: :webhook}) do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp webhook_secret(_existing, _spec), do: nil

  defp cron_expression(%{kind: :schedule, params: %{"cron" => cron}}, _config)
       when is_binary(cron),
       do: cron

  defp cron_expression(%{kind: :schedule}, %{"cron_expression" => cron}) when is_binary(cron),
    do: cron

  defp cron_expression(_spec, _config), do: nil

  defp schedule_next_fire_at(%TriggerRegistration{} = existing, spec, _now) do
    case existing.config_digest == digest_for(spec) do
      true -> existing.next_fire_at || next_fire_at(spec.params)
      false -> next_fire_at(spec.params)
    end
  end

  defp schedule_next_fire_at(nil, spec, _now), do: next_fire_at(spec.params)

  defp polling_cursor(%{kind: kind, params: params}) when kind in [:polling, :subscription] do
    Map.get(params, "cursor_init")
  end

  defp polling_cursor(_spec), do: nil

  defp polling_interval(%{params: params}) do
    Map.get(params, "poll_interval_ms")
  end

  defp batch_size(%{params: params}) do
    Map.get(params, "batch_size", 100)
  end

  defp parse_cron(cron) do
    {:ok, Expression.parse!(cron)}
  rescue
    _error -> :error
  end

  defp normalize_next_fire_at(:unknown), do: nil
  defp normalize_next_fire_at(%DateTime{} = datetime), do: datetime

  defp notify_stale_registrations(_workflow_definition_id) do
    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT pg_notify($1, $2)",
           ["trigger_registrations", Jason.encode!(%{"event" => "refresh"})]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("trigger registration notify failed: #{inspect(reason)}")
    end
  end
end
