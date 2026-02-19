defmodule Fizz.Runtime.Triggers.Activator do
  @moduledoc """
  Activates and deactivates triggers for workflows.
  Called when workflows are published, archived, or deleted.
  """
  require Logger
  alias Fizz.Runtime.Triggers.{Registry, ScheduleManager}
  alias Fizz.Workflows.Workflow

  @doc """
  Activates all triggers for a workflow.
  """
  def activate(%Workflow{} = workflow) do
    Logger.info("Activating triggers for workflow: #{workflow.id}")

    # 1. Extract triggers from steps
    workflow = Fizz.Repo.preload(workflow, [:published_version, :draft])
    steps = get_steps(workflow)

    webhooks =
      steps
      |> Enum.filter(&(&1.type_id == "webhook_trigger"))
      |> Enum.map(fn step ->
        path = Map.get(step.config, "path") || Map.get(step.config, :path) || step.id

        method =
          Map.get(step.config, "http_method") || Map.get(step.config, :http_method) ||
            Map.get(step.config, "method") || Map.get(step.config, :method) || "POST"

        %{
          path: normalize_path(path),
          method: normalize_method(method),
          config: step.config
        }
      end)

    # 2. Register in the active registry
    Registry.register(workflow.id, webhooks: webhooks)

    # 3. Activate specific triggers (schedules)

    Enum.each(steps, fn step ->
      case step.type_id do
        "schedule_trigger" ->
          ScheduleManager.activate(workflow.id, step.config)

        "webhook_trigger" ->
          # Already handled by Registry.register above
          :ok

        _ ->
          :ok
      end
    end)
  end

  @doc """
  Deactivates all triggers for a workflow.
  """
  def deactivate(workflow_id) do
    Logger.info("Deactivating triggers for workflow: #{workflow_id}")

    # 1. Unregister from registry
    Registry.unregister(workflow_id)

    # 2. Stop schedules
    ScheduleManager.deactivate(workflow_id)
  end

  defp normalize_path(nil), do: nil

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_method(nil), do: "POST"

  defp normalize_method(method) when is_binary(method) do
    method
    |> String.trim()
    |> case do
      "" -> "POST"
      trimmed -> String.upcase(trimmed)
    end
  end

  defp get_steps(%{published_version: %{steps: steps}}) when not is_nil(steps), do: steps
  defp get_steps(%{draft: %{steps: steps}}) when not is_nil(steps), do: steps
  defp get_steps(_), do: []
end
