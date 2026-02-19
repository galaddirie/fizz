defmodule Fizz.Steps.Executors.OpenAIModel do
  @moduledoc """
  Produces OpenAI-specific model configuration for AI agent steps.
  """

  use Fizz.Steps.Definition,
    id: "openai_model",
    name: "OpenAI Model",
    category: "AI",
    description: "Configure OpenAI model parameters for AI agent steps",
    icon: "hero-variable",
    kind: :transform,
    role: :subnode

  @behaviour Fizz.Steps.Executors.Behaviour

  @default_config %{
    "model" => "gpt-4.1-mini",
    "temperature" => 0.2,
    "max_tokens" => 800
  }

  @config_schema %{
    "type" => "object",
    "required" => ["model"],
    "properties" => %{
      "model" => %{
        "type" => "string",
        "title" => "Model",
        "default" => "gpt-4.1-mini",
        "description" => "OpenAI model name"
      },
      "temperature" => %{
        "type" => "number",
        "title" => "Temperature",
        "default" => 0.2,
        "description" => "Sampling temperature (0-2)"
      },
      "max_tokens" => %{
        "type" => "integer",
        "title" => "Max Tokens",
        "default" => 800,
        "description" => "Maximum completion tokens"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "provider" => %{"type" => "string"},
      "model" => %{"type" => "string"},
      "temperature" => %{"type" => "number"},
      "max_tokens" => %{"type" => "integer"}
    }
  }

  @impl true
  def default_config, do: @default_config

  @impl true
  def execute(config, _input, _ctx) do
    {:ok,
     %{
       "provider" => "openai_api_key",
       "model" => Map.get(config, "model", "gpt-4.1-mini"),
       "temperature" => normalize_temperature(Map.get(config, "temperature", 0.2)),
       "max_tokens" => normalize_max_tokens(Map.get(config, "max_tokens", 800))
     }}
  end

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "model") do
        model when is_binary(model) and model != "" -> errors
        _ -> [{:model, "is required"} | errors]
      end

    errors =
      case Map.get(config, "temperature", 0.2) do
        t when is_number(t) and t >= 0 and t <= 2 -> errors
        _ -> [{:temperature, "must be a number between 0 and 2"} | errors]
      end

    errors =
      case Map.get(config, "max_tokens", 800) do
        max when is_integer(max) and max > 0 -> errors
        _ -> [{:max_tokens, "must be a positive integer"} | errors]
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp normalize_temperature(value) when is_number(value), do: value
  defp normalize_temperature(_), do: 0.2

  defp normalize_max_tokens(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_tokens(_), do: 800
end
