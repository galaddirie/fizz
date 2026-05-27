defmodule Fizz.Integrations.Fizz.Builtins.ScheduleTriggerTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Fizz.Builtins.ScheduleTrigger
  alias Fizz.Triggers.RegistrationSpec

  test "registration_spec/2 returns a schedule registration spec with cron params" do
    config = %{"cron_expression" => "0 9 * * MON-FRI", "timezone" => "UTC"}

    assert {:ok,
            %RegistrationSpec{
              kind: :schedule,
              params: %{
                "cron" => "0 9 * * MON-FRI",
                "timezone" => "UTC"
              }
            }} = ScheduleTrigger.registration_spec(config, %{})
  end

  test "normalize_event/2 produces a scheduled_at timestamp" do
    assert {:ok, %{"scheduled_at" => scheduled_at}} = ScheduleTrigger.normalize_event(%{}, %{})
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(scheduled_at)
  end

  test "validate_config/1 accepts a cron expression" do
    assert :ok = ScheduleTrigger.validate_config(%{"cron_expression" => "*/15 * * * *"})
  end

  test "validate_config/1 accepts an interval" do
    assert :ok = ScheduleTrigger.validate_config(%{"interval_seconds" => 60})
  end

  test "validate_config/1 rejects missing cron and interval" do
    assert {:error, [schedule: "must provide cron_expression or interval_seconds"]} =
             ScheduleTrigger.validate_config(%{})
  end
end
