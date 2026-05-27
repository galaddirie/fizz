defmodule Fizz.Integrations.Fizz.Builtins.Wait do
  @moduledoc """
  Executor for Wait steps.

  Pauses execution for a specified duration before continuing. Useful for
  rate limiting, delays between API calls, or simulating processing time.

  ## Configuration

  - `duration` (required) - Duration to wait in milliseconds
  - `unit` (optional) - Time unit: "milliseconds", "seconds", "minutes". Default: "milliseconds"

  ## Input Handling

  This step uses **automatic input wiring**. The previous step's output
  is passed through unchanged after the wait period.
  """

  use Fizz.Integrations.StepDefinition,
    id: "wait",
    name: "Wait",
    category: "Control Flow",
    description: "Pause execution for a specified duration",
    icon: "hero-clock",
    kind: :control_flow,
    integration: "fizz"

  alias Fizz.Fields

  @fields [
    Fields.number("duration",
      label: "Duration",
      required?: true,
      minimum: 1,
      default: 1000,
      description: "Amount of time to wait"
    ),
    Fields.select("unit",
      label: "Unit",
      default: "milliseconds",
      description: "Time unit for the duration",
      options: Fields.options(~w(milliseconds seconds minutes))
    )
  ]

  @input_schema %{
    "description" => "Receives previous step output automatically"
  }

  @output_schema %{
    "description" => "The input data, unchanged"
  }

  @behaviour Fizz.Workflows.StepExecutor
  require Logger

  @impl true
  def execute(config, input, _execution) do
    duration = Map.get(config, "duration", 1000)
    unit = Map.get(config, "unit", "milliseconds")

    milliseconds = convert_to_milliseconds(duration, unit)

    Logger.info("Wait step: scheduling durable sleep for #{milliseconds}ms (#{duration} #{unit})")

    {:ok, {:sleep, milliseconds, input}}
  end

  @impl true
  def validate_config(config) do
    duration = Map.get(config, "duration")
    unit = Map.get(config, "unit", "milliseconds")

    cond do
      not is_integer(duration) or duration < 1 ->
        {:error, [duration: "must be a positive integer"]}

      unit not in ["milliseconds", "seconds", "minutes"] ->
        {:error, [unit: "must be one of: milliseconds, seconds, minutes"]}

      true ->
        :ok
    end
  end

  # Convert duration to milliseconds
  defp convert_to_milliseconds(duration, "milliseconds"), do: duration
  defp convert_to_milliseconds(duration, "seconds"), do: duration * 1000
  defp convert_to_milliseconds(duration, "minutes"), do: duration * 60 * 1000
end
