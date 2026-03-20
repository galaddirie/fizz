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
    "required" => ["interval_seconds"],
    "properties" => %{
      "interval_seconds" => %{
        "type" => "integer",
        "title" => "Interval (seconds)",
        "minimum" => 60,
        "default" => 3600
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
           "timezone" => Map.get(config, "timezone", "UTC"),
           "jitter_seconds" => Map.get(config, "jitter_seconds", 0)
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
  def normalize_event(_config, raw_event) when is_map(raw_event), do: {:ok, raw_event}

  @impl true
  def effective_output_schema(config) do
    Map.get(config, "output_schema") || @output_schema
  end

  @impl true
  def validate_config(config) do
    interval = Map.get(config, "interval_seconds")

    if is_integer(interval) and interval >= 1 do
      :ok
    else
      {:error, [interval_seconds: "must be a positive integer"]}
    end
  end
end
