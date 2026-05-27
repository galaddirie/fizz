defmodule Fizz.Triggers.RegistrationManager do
  @moduledoc """
  Synchronizes durable trigger registrations from compiled workflow metadata.
  """

  import Ecto.Query

  alias Fizz.Accounts.Scope
  alias Fizz.Fields.Credential
  alias Fizz.Repo
  alias Fizz.Steps.Executor, as: StepExecutorBehaviour
  alias Fizz.Triggers
  alias Fizz.Triggers.Webhook
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Triggers.Workers.TriggerFireWorker
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.WorkflowDefinition
  alias Fizz.Workflows.WorkflowDefinitionVersion
  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler, as: CronScheduler

  require Logger

  @type sync_error :: %{step_id: String.t(), reason: term()}

  @spec sync_on_publish(WorkflowDefinitionVersion.t()) :: :ok | {:error, [sync_error()]}
  def sync_on_publish(%WorkflowDefinitionVersion{} = definition_version) do
    with {:ok, workflow, _compiled_hash} <- Compiler.compile(definition_version),
         {:ok, context} <- load_definition_context(definition_version) do
      _ = deactivate_stale_registrations(definition_version)

      errors = credential_binding_errors(definition_version, context)

      errors =
        case errors do
          [] ->
            workflow.fizz_metadata
            |> Map.get(:trigger_manifest, [])
            |> Enum.reduce([], fn trigger, acc ->
              case sync_trigger(trigger, context) do
                :ok -> acc
                {:error, reason} -> [%{step_id: trigger.step_id, reason: reason} | acc]
              end
            end)
            |> Enum.reverse()

          _ ->
            errors
        end

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
    with {:ok, expression} <- parse_cron(cron),
         {:ok, timezone_now} <- shift_to_timezone(from, timezone),
         {:ok, next_run} <- CronScheduler.get_next_run_date(expression, timezone_now) do
      normalize_next_fire_at(next_run, timezone)
    else
      {:error, _reason} -> nil
    end
  end

  def next_fire_at(%{"cron" => cron}, %DateTime{} = from) when is_binary(cron) do
    next_fire_at(%{"cron" => cron, "timezone" => "UTC"}, from)
  end

  def next_fire_at(_params, _from), do: nil

  defp sync_trigger(trigger, context) do
    with {:ok, executor} <- StepExecutorBehaviour.resolve(trigger.type_id),
         {:ok, config} <- resolve_trigger_config(trigger, context),
         {:ok, spec} <- executor.registration_spec(config, context),
         {:ok, trigger_source} <- maybe_upsert_source(spec, context),
         attrs <- registration_attrs(trigger, spec, context, trigger_source),
         {:ok, registration} <- Triggers.upsert_registration(attrs) do
      maybe_enqueue_initial_schedule(registration, executor)
      :ok
    end
  end

  defp maybe_enqueue_initial_schedule(
         %TriggerRegistration{kind: "schedule", next_fire_at: %DateTime{} = fire_at} =
           registration,
         executor
       ) do
    event_id = "sched_#{registration.id}_#{DateTime.to_unix(fire_at)}"

    normalized_data =
      case executor.normalize_event(registration.registration_params, %{}) do
        {:ok, data} -> Map.put(data, "scheduled_at", DateTime.to_iso8601(fire_at))
        {:error, _} -> %{"scheduled_at" => DateTime.to_iso8601(fire_at)}
      end

    %{
      "trigger_registration_id" => registration.id,
      "event_id" => event_id,
      "normalized_data" => normalized_data
    }
    |> TriggerFireWorker.new(scheduled_at: fire_at)
    |> Oban.insert()

    :ok
  end

  defp maybe_enqueue_initial_schedule(_registration, _executor), do: :ok

  defp resolve_trigger_config(trigger, context) do
    scope = %Scope{organization_id: context.workos_organization_id}

    run_attrs = %{
      user_id: context.user_id,
      workflow_definition_id: context.workflow_definition_id,
      workos_organization_id: context.workos_organization_id
    }

    with {:ok, resolver} <- Credential.runtime_resolver(scope, run_attrs),
         {:ok, config} <- resolve_credentials(trigger.config, trigger.step_id, resolver) do
      {:ok, config}
    end
  end

  defp resolve_credentials(value, step_id, resolver) when is_map(value) do
    if Credential.declaration?(value) do
      with {:ok, %{requirement_key: requirement_key, provider: provider, auth_type: auth_type}} <-
             Credential.normalize(value),
           {:ok, resolved} <- resolver.(requirement_key, step_id, provider, auth_type) do
        {:ok, resolved}
      end
    else
      Enum.reduce_while(value, {:ok, %{}}, fn {key, child}, {:ok, acc} ->
        case resolve_credentials(child, step_id, resolver) do
          {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp resolve_credentials(values, step_id, resolver) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case resolve_credentials(value, step_id, resolver) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_credentials(value, _step_id, _resolver), do: {:ok, value}

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
               workos_organization_id: definition.workos_organization_id,
               user_id: coalesce(version.published_by_user_id, definition.created_by_user_id)
             }
           )
         ) do
      nil -> {:error, :version_not_found}
      context -> {:ok, context}
    end
  end

  defp credential_binding_errors(%WorkflowDefinitionVersion{} = definition_version, context) do
    scope = %Scope{
      user: %{id: context.user_id},
      organization_id: context.workos_organization_id
    }

    case Credential.readiness(definition_version, context.user_id, scope) do
      :ready ->
        []

      {:needs_bindings, descriptors} ->
        Enum.map(descriptors, fn descriptor ->
          %{
            step_id: descriptor.step_id,
            reason: credential_binding_error_reason(descriptor)
          }
        end)
    end
  end

  defp credential_binding_error_reason(%{requirement_key: key, reason: :credential_unbound}) do
    {:credential_binding_required, key}
  end

  defp credential_binding_error_reason(%{requirement_key: key, reason: reason}) do
    {:credential_binding_invalid, key, reason}
  end

  defp credential_binding_error_reason(%{requirement_key: key}) do
    {:credential_binding_required, key}
  end

  defp registration_attrs(trigger, spec, context, trigger_source) do
    params = spec.params || %{}
    now = DateTime.utc_now()

    existing =
      current_registration(context.definition_version_id, trigger.step_id, context.user_id)

    existing_webhook =
      webhook_registration(
        existing,
        context.workflow_definition_id,
        context.user_id,
        trigger,
        spec
      )

    %{
      workflow_definition_id: context.workflow_definition_id,
      definition_version_id: context.definition_version_id,
      step_id: trigger.step_id,
      user_id: context.user_id,
      project_id: context.project_id,
      trigger_source_id: trigger_source && trigger_source.id,
      workos_organization_id: context.workos_organization_id,
      run_id: nil,
      kind: Atom.to_string(spec.kind),
      status: "active",
      registration_params: params,
      config_digest: digest_for(spec),
      webhook_path: webhook_path(existing_webhook, spec),
      webhook_secret: webhook_secret(existing_webhook, spec),
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

  defp maybe_upsert_source(%{kind: kind, source_module: source_module} = spec, context)
       when kind in [:polling, :subscription] and is_atom(source_module) do
    with {:module, ^source_module} <- Code.ensure_loaded(source_module),
         {:ok, cursor} <- source_module.init_cursor(spec.params || %{}, context),
         {:ok, provider} <- source_provider(spec),
         source_key <- spec.source_key || source_module.source_key(spec.params || %{}, context) do
      Triggers.upsert_source(%{
        project_id: context.project_id,
        workos_organization_id: context.workos_organization_id,
        user_id: context.user_id,
        kind: Atom.to_string(kind),
        provider: provider,
        source_module: module_name(source_module),
        source_key: source_key,
        status: "active",
        params: spec.params || %{},
        cursor: cursor,
        poll_interval_ms: polling_interval(spec) || 60_000,
        next_poll_at: DateTime.utc_now(),
        error_message: nil,
        consecutive_errors: 0,
        last_error_at: nil
      })
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trigger_source_module}
    end
  end

  defp maybe_upsert_source(%{kind: kind}, _context) when kind in [:polling, :subscription],
    do: {:error, :trigger_source_module_required}

  defp maybe_upsert_source(_spec, _context), do: {:ok, nil}

  defp current_registration(definition_version_id, step_id, user_id) do
    TriggerRegistration
    |> where(
      [registration],
      registration.definition_version_id == ^definition_version_id and
        registration.step_id == ^step_id and registration.user_id == ^user_id and
        is_nil(registration.run_id)
    )
    |> Repo.one()
  end

  defp prior_webhook_registration(workflow_definition_id, step_id, user_id) do
    TriggerRegistration
    |> where(
      [registration],
      registration.workflow_definition_id == ^workflow_definition_id and
        registration.step_id == ^step_id and registration.user_id == ^user_id and
        registration.kind == "webhook" and is_nil(registration.run_id)
    )
    |> order_by([registration], desc: registration.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp webhook_registration(
         %TriggerRegistration{} = existing,
         _definition_id,
         _user_id,
         _trigger,
         %{
           kind: :webhook
         }
       ),
       do: existing

  defp webhook_registration(nil, workflow_definition_id, user_id, trigger, %{kind: :webhook}) do
    prior_webhook_registration(workflow_definition_id, trigger.step_id, user_id)
  end

  defp webhook_registration(_existing, _definition_id, _user_id, _trigger, _spec), do: nil

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
    Webhook.generate_path()
  end

  defp webhook_path(_existing, _spec), do: nil

  defp webhook_secret(%TriggerRegistration{webhook_secret: secret}, %{kind: :webhook})
       when is_binary(secret) and secret != "",
       do: secret

  defp webhook_secret(_existing, %{kind: :webhook}), do: Webhook.generate_secret()

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

  defp source_provider(%{provider: provider}) when is_binary(provider) and provider != "",
    do: {:ok, provider}

  defp source_provider(%{params: %{"provider" => provider}})
       when is_binary(provider) and provider != "",
       do: {:ok, provider}

  defp source_provider(_spec), do: {:error, :trigger_source_provider_required}

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp parse_cron(cron) do
    CronParser.parse(cron)
  end

  defp shift_to_timezone(%DateTime{} = from, "UTC"), do: {:ok, DateTime.to_naive(from)}
  defp shift_to_timezone(%DateTime{} = from, "Etc/UTC"), do: {:ok, DateTime.to_naive(from)}

  defp shift_to_timezone(%DateTime{} = from, timezone) do
    case DateTime.shift_zone(from, timezone) do
      {:ok, shifted} -> {:ok, DateTime.to_naive(shifted)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_next_fire_at(%NaiveDateTime{} = naive_datetime, "UTC") do
    DateTime.from_naive!(naive_datetime, "Etc/UTC")
  end

  defp normalize_next_fire_at(%NaiveDateTime{} = naive_datetime, "Etc/UTC") do
    DateTime.from_naive!(naive_datetime, "Etc/UTC")
  end

  defp normalize_next_fire_at(%NaiveDateTime{} = naive_datetime, timezone) do
    with {:ok, datetime} <- DateTime.from_naive(naive_datetime, timezone),
         {:ok, utc_datetime} <- DateTime.shift_zone(datetime, "Etc/UTC") do
      utc_datetime
    else
      {:error, _reason} -> nil
      {:ambiguous, _first, _second} -> nil
      {:gap, _before, _after} -> nil
    end
  end

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
