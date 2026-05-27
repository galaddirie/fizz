defmodule Fizz.Integrations.Library.Fizz do
  @moduledoc """
  Fizz product-domain integration.

  Built-in workflow nodes are owned here so every executable step belongs to an
  integration domain. Declaration metadata lives in `Fizz.Integrations` and
  execution behavior lives in `Fizz.Workflows`.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
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
      Fizz.Integrations.Library.Fizz.Builtins.ManualInput,
      Fizz.Integrations.Library.Fizz.Builtins.OnChatTrigger,
      Fizz.Integrations.Library.Fizz.Builtins.HttpRequest,
      Fizz.Integrations.Library.Fizz.Builtins.JsonParser,
      Fizz.Integrations.Library.Fizz.Builtins.DataFilter,
      Fizz.Integrations.Library.Fizz.Builtins.DataTransform,
      Fizz.Integrations.Library.Fizz.Builtins.DataOutput,
      Fizz.Integrations.Library.Fizz.Builtins.Condition,
      Fizz.Integrations.Library.Fizz.Builtins.Switch,
      Fizz.Integrations.Library.Fizz.Builtins.Format,
      Fizz.Integrations.Library.Fizz.Builtins.Debug,
      Fizz.Integrations.Library.Fizz.Builtins.Math,
      Fizz.Integrations.Library.Fizz.Builtins.Aggregator,
      Fizz.Integrations.Library.Fizz.Builtins.Splitter,
      Fizz.Integrations.Library.Fizz.Builtins.Join,
      Fizz.Integrations.Library.Fizz.Builtins.ScheduleTrigger,
      Fizz.Integrations.Library.Fizz.Builtins.Wait,
      Fizz.Integrations.Library.Fizz.Builtins.AIAgent,
      Fizz.Integrations.Library.Fizz.Builtins.AIStructureSchema,
      Fizz.Integrations.Library.Fizz.Builtins.AIToolHttp
    ]
end
