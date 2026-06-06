defmodule Fizz.Integrations.Library.Fizz.Builtins.ManualInputTriggerTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Library.Fizz.Builtins.ManualInput
  alias Fizz.Triggers.RegistrationSpec

  test "registration_spec/2 returns a manual registration spec" do
    config = %{
      "input_schema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
    }

    assert {:ok,
            %RegistrationSpec{
              kind: :manual,
              params: %{"input_schema" => input_schema}
            }} = ManualInput.registration_spec(config, %{})

    assert input_schema == config["input_schema"]
  end

  test "normalize_event/2 passes through input" do
    raw_event = %{"name" => "Ada", "count" => 3}

    assert {:ok, ^raw_event} = ManualInput.normalize_event(%{}, raw_event)
  end
end
