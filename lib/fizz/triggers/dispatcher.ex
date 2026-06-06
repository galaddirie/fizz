defmodule Fizz.Triggers.Dispatcher do
  @moduledoc """
  Durable boundary between trigger source detection and workflow execution.
  """

  alias Fizz.Repo
  alias Fizz.Triggers
  alias Fizz.Triggers.TriggerEvent
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Triggers.Workers.TriggerFireWorker

  @spec dispatch(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def dispatch(registration_id, event_id, normalized_data)
      when is_binary(registration_id) and is_binary(event_id) and is_map(normalized_data) do
    Repo.transaction(fn ->
      case Triggers.begin_event_pending(registration_id, event_id, normalized_data) do
        {:ok, _event} ->
          insert_fire_job!(registration_id, event_id, normalized_data)

        {:error, :duplicate, %TriggerEvent{status: "failed"}} ->
          insert_fire_job!(registration_id, event_id, normalized_data)

        {:error, :duplicate, %TriggerEvent{}} ->
          :ok

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec dispatch_to_source_registrations(String.t(), map(), String.t()) :: :ok | {:error, term()}
  def dispatch_to_source_registrations(source_id, raw_event, event_id)
      when is_binary(source_id) and is_map(raw_event) and is_binary(event_id) do
    source_id
    |> Triggers.list_registrations_for_source()
    |> Enum.reduce_while(:ok, fn registration, :ok ->
      case dispatch_to_registration(registration, raw_event, event_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp dispatch_to_registration(%TriggerRegistration{} = registration, raw_event, event_id) do
    with {:ok, executor} <- Triggers.resolve_registration_executor(registration),
         {:ok, normalized_data} <-
           executor.normalize_event(registration.registration_params, raw_event) do
      dispatch(registration.id, event_id, normalized_data)
    end
  end

  defp insert_fire_job!(registration_id, event_id, normalized_data) do
    %{
      "trigger_registration_id" => registration_id,
      "event_id" => event_id,
      "normalized_data" => normalized_data
    }
    |> TriggerFireWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
