defmodule Fizz.Steps.Executors.AnthropicModel do
  @moduledoc """
  Produces Anthropic-specific model configuration for AI agent steps.

  Execution against Anthropic is not implemented yet in `ai_agent`.
  """

  use Fizz.Steps.Definition,
    id: "anthropic_model",
    name: "Anthropic Model",
    category: "AI",
    description: "Configure Anthropic model parameters for AI agent steps",
    icon: "/images/anthropic.svg",
    kind: :transform,
    role: :subnode

  @behaviour Fizz.Steps.Executor

  alias Fizz.Integrations.CredentialRef
  alias Fizz.Integrations.Providers.AnthropicApiKey
  alias Fizz.Fields

  @credential_field Fields.credential(AnthropicApiKey.provider_id(), :api_key,
                      key: "credential_ref",
                      label: "Credential",
                      description: "Anthropic credential. Bound at run time per user.",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("model",
      label: "Model",
      required?: true,
      default: "claude-3-5-sonnet-latest",
      description: "Anthropic model name"
    ),
    Fields.number("temperature",
      label: "Temperature",
      default: 0.2,
      description: "Sampling temperature (0-1)"
    ),
    Fields.number("max_tokens",
      label: "Max Tokens",
      default: 800,
      description: "Maximum completion tokens"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "provider" => %{"type" => "string"},
      "credential_ref" => %{"type" => "object"},
      "model" => %{"type" => "string"},
      "temperature" => %{"type" => "number"},
      "max_tokens" => %{"type" => "integer"}
    }
  }

  @impl true
  def execute(config, _input, _ctx) do
    with {:ok, credential_ref} <- normalize_credential_ref(config) do
      {:ok,
       %{
         "provider" => "anthropic_api_key",
         "credential_ref" => credential_ref,
         "model" => Map.get(config, "model", "claude-3-5-sonnet-latest"),
         "temperature" => normalize_temperature(Map.get(config, "temperature", 0.2)),
         "max_tokens" => normalize_max_tokens(Map.get(config, "max_tokens", 800))
       }}
    end
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
        t when is_number(t) and t >= 0 and t <= 1 -> errors
        _ -> [{:temperature, "must be a number between 0 and 1"} | errors]
      end

    errors = credential_ref_errors(config, errors)

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

  defp normalize_credential_ref(config) do
    credential_ref =
      Map.get(config, "credential_ref") ||
        Map.get(config, :credential_ref)

    CredentialRef.normalize_for_provider(credential_ref, "anthropic_api_key", :api_key)
  end

  defp credential_ref_errors(config, errors) do
    credential_ref =
      Map.get(config, "credential_ref") ||
        Map.get(config, :credential_ref)

    cond do
      Fields.Credential.declaration?(credential_ref) ->
        errors

      true ->
        case CredentialRef.normalize_for_provider(credential_ref, "anthropic_api_key", :api_key) do
          {:ok, _credential_ref} -> errors
          {:error, :credential_ref_required} -> [{:credential_ref, "is required"} | errors]
          {:error, _reason} -> [{:credential_ref, "is invalid"} | errors]
        end
    end
  end
end
