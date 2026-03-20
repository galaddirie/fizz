defmodule Fizz.Steps.Executors.ScheduleTrigger do
  @moduledoc """
  Trigger node that initiates execution on a schedule.

  ## Configuration

  - `interval_seconds` (required) - Frequency of execution.

  ## Output

  Timing metadata about the trigger occurrence.
  """
  use Fizz.Steps.Definition,
    id: "schedule_trigger",
    name: "Schedule Trigger",
    category: "Triggers",
    description: "Starts the workflow on a recurring schedule",
    icon: "hero-clock",
    kind: :trigger

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "cron_expression" => %{
        "type" => "string",
        "title" => "Cron Expression",
        "description" => "Cron syntax for recurring runs, e.g. 0 9 * * MON-FRI"
      },
      "interval_seconds" => %{
        "type" => "integer",
        "title" => "Interval (seconds)",
        "minimum" => 1,
        "default" => 3600
      },
      "timezone" => %{
        "type" => "string",
        "title" => "Timezone",
        "default" => "UTC"
      },
      "output_schema" => %{
        "type" => "object",
        "title" => "Output Schema",
        "description" => "JSON Schema describing the trigger output"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "scheduled_at" => %{"type" => "string", "format" => "date-time"}
    }
  }

  @behaviour Fizz.Steps.Executors.Behaviour
  alias Fizz.Triggers.RegistrationSpec

  @impl true
  def registration_spec(config, _context) do
    {:ok,
     %RegistrationSpec{
       kind: :schedule,
       params:
         %{
           "cron" => Map.get(config, "cron_expression"),
           "interval_seconds" => Map.get(config, "interval_seconds"),
           "timezone" => Map.get(config, "timezone", "UTC")
         }
         |> Enum.reject(fn {_key, value} -> is_nil(value) end)
         |> Map.new()
     }}
  end

  @impl true
  def execute(_config, input, _context) do
    {:ok, input}
  end

  @impl true
  def normalize_event(_config, _raw_event) do
    {:ok, %{"scheduled_at" => DateTime.utc_now() |> DateTime.to_iso8601()}}
  end

  @impl true
  def effective_output_schema(config) do
    Map.get(config, "output_schema") || @output_schema
  end

  @impl true
  def validate_config(config) do
    interval = Map.get(config, "interval_seconds")
    cron_expression = Map.get(config, "cron_expression")

    cond do
      valid_cron_expression?(cron_expression) ->
        :ok

      is_integer(interval) and interval > 0 ->
        :ok

      present?(cron_expression) ->
        {:error, [cron_expression: "must be a valid cron expression"]}

      true ->
        {:error, [schedule: "must provide cron_expression or interval_seconds"]}
    end
  end

  defp valid_cron_expression?(cron_expression) when is_binary(cron_expression) do
    case Crontab.CronExpression.Parser.parse(cron_expression) do
      {:ok, _expression} -> true
      _ -> false
    end
  end

  defp valid_cron_expression?(_cron_expression), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
