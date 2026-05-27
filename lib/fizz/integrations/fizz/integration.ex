defmodule Fizz.Integrations.Fizz do
  @moduledoc """
  Fizz product-domain integration.

  Built-in workflow nodes are owned here so every executable step belongs to an
  integration domain. Declaration metadata lives in `Fizz.Integrations` and
  execution behavior lives in `Fizz.Workflows`.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "fizz",
    display_name: "Fizz",
    actions: [
      "ai_agent",
      "aggregator",
      "condition",
      "data_filter",
      "data_output",
      "data_transform",
      "debug",
      "format",
      "http_request",
      "join",
      "json_parser",
      "math",
      "splitter",
      "switch",
      "wait"
    ],
    step_modules: [
      Fizz.Integrations.Fizz.Builtins.ManualInput,
      Fizz.Integrations.Fizz.Builtins.OnChatTrigger,
      Fizz.Integrations.Fizz.Builtins.HttpRequest,
      Fizz.Integrations.Fizz.Builtins.JsonParser,
      Fizz.Integrations.Fizz.Builtins.DataFilter,
      Fizz.Integrations.Fizz.Builtins.DataTransform,
      Fizz.Integrations.Fizz.Builtins.DataOutput,
      Fizz.Integrations.Fizz.Builtins.Condition,
      Fizz.Integrations.Fizz.Builtins.Switch,
      Fizz.Integrations.Fizz.Builtins.Format,
      Fizz.Integrations.Fizz.Builtins.Debug,
      Fizz.Integrations.Fizz.Builtins.Math,
      Fizz.Integrations.Fizz.Builtins.Aggregator,
      Fizz.Integrations.Fizz.Builtins.Splitter,
      Fizz.Integrations.Fizz.Builtins.Join,
      Fizz.Integrations.Fizz.Builtins.ScheduleTrigger,
      Fizz.Integrations.Fizz.Builtins.Wait,
      Fizz.Integrations.Fizz.Builtins.AIAgent,
      Fizz.Integrations.Fizz.Builtins.AIStructureSchema,
      Fizz.Integrations.Fizz.Builtins.AIToolHttp
    ]
end
