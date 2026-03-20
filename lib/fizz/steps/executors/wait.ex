defmodule Fizz.Steps.Executors.Wait do
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

  use Fizz.Steps.Definition,
    id: "wait",
    name: "Wait",
    category: "Control Flow",
    description: "Pause execution for a specified duration",
    icon: "hero-clock",
    kind: :control_flow

  @config_schema %{
    "type" => "object",
    "required" => ["duration"],
    "properties" => %{
      "duration" => %{
        "type" => "integer",
        "title" => "Duration",
        "minimum" => 1,
        "default" => 1000,
        "description" => "Amount of time to wait"
      },
      "unit" => %{
        "type" => "string",
        "title" => "Unit",
        "enum" => ["milliseconds", "seconds", "minutes"],
        "default" => "milliseconds",
        "description" => "Time unit for the duration"
      }
    }
  }

  @input_schema %{
    "description" => "Receives previous step output automatically"
  }

  @output_schema %{
    "description" => "The input data, unchanged"
  }

  @behaviour Fizz.Steps.Executors.Behaviour
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

  @impl true
  def default_config do
    %{
      "duration" => 1000,
      "unit" => "milliseconds"
    }
  end

  # Convert duration to milliseconds
  defp convert_to_milliseconds(duration, "milliseconds"), do: duration
  defp convert_to_milliseconds(duration, "seconds"), do: duration * 1000
  defp convert_to_milliseconds(duration, "minutes"), do: duration * 60 * 1000
end
