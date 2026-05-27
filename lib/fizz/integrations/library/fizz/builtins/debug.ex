defmodule Fizz.Integrations.Library.Fizz.Builtins.Debug do
  @moduledoc """
  Executor for Debug steps.

  Logs the input data and passes it through unchanged. Useful for inspecting
  data flow in a workflow.

  ## Configuration

  - `label` (optional) - A label to prefix the log message with
  - `level` (optional) - The log level (debug, info, warn, error). Default: info

  ## Input Handling

  This step uses **automatic input wiring**. The previous step's output
  is logged and passed through unchanged.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "debug",
    name: "Debug",
    category: "Utilities",
    description: "Log input data and pass it through unchanged for debugging",
    icon: "hero-bug-ant",
    kind: :action,
    integration: "fizz"

  alias Fizz.Fields

  @fields [
    Fields.string("label",
      label: "Label",
      default: "Debug Step",
      description: "Label to prefix the log message"
    ),
    Fields.select("level",
      label: "Log Level",
      default: "info",
      description: "The log level to use",
      options: Fields.options(~w(debug info warn error))
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
    label = Map.get(config, "label", "Debug Step")
    level = normalize_level(Map.get(config, "level", "info"))

    message = "#{label}: #{inspect(input, pretty: true)}"

    case level do
      :debug -> Logger.debug(message)
      :info -> Logger.info(message)
      :warn -> Logger.warning(message)
      :error -> Logger.error(message)
      _ -> Logger.info(message)
    end

    {:ok, input}
  end

  @impl true
  def validate_config(config) do
    level = Map.get(config, "level", "info")

    if level in ~w(debug info warn error) do
      :ok
    else
      {:error, [level: "must be one of: debug, info, warn, error"]}
    end
  end

  defp normalize_level(level) when is_atom(level) and level in [:debug, :info, :warn, :error] do
    level
  end

  defp normalize_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warn" -> :warn
      "error" -> :error
      _ -> :info
    end
  end

  defp normalize_level(_level), do: :info
end
