defmodule Fizz.Steps.Executors.OpenAIModel do
  @moduledoc """
  Produces OpenAI-specific model configuration for AI agent steps.
  """

  use Fizz.Steps.Definition,
    id: "openai_model",
    name: "OpenAI Model",
    category: "AI",
    description: "Configure OpenAI model parameters for AI agent steps",
    icon: "/images/openai.svg",
    kind: :transform,
    role: :subnode

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.CredentialRef

  @default_config %{
    "model" => "gpt-4.1-mini",
    "temperature" => 0.2,
    "max_tokens" => 800,
    "credential_ref" => nil
  }

  @config_schema %{
    "type" => "object",
    "required" => ["model", "credential_ref"],
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Credential",
        "description" => "Select the OpenAI credential to use for execution",
        "ui" => %{
          "component" => "select",
          "resolver" => "credentials",
          "params" => %{
            "provider_filter" => ["openai_api_key"],
            "auth_types" => ["api_key"]
          }
        }
      },
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
      "credential_ref" => %{"type" => "object"},
      "model" => %{"type" => "string"},
      "temperature" => %{"type" => "number"},
      "max_tokens" => %{"type" => "integer"}
    }
  }

  @impl true
  def default_config, do: @default_config

  @impl true
  def execute(config, _input, _ctx) do
    with {:ok, credential_ref} <- normalize_credential_ref(config) do
      {:ok,
       %{
         "provider" => "openai_api_key",
         "credential_ref" => credential_ref,
         "model" => Map.get(config, "model", "gpt-4.1-mini"),
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
        t when is_number(t) and t >= 0 and t <= 2 -> errors
        _ -> [{:temperature, "must be a number between 0 and 2"} | errors]
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

    CredentialRef.normalize_for_provider(credential_ref, "openai_api_key", :api_key)
  end

  defp credential_ref_errors(config, errors) do
    case normalize_credential_ref(config) do
      {:ok, _credential_ref} ->
        errors

      {:error, :credential_ref_required} ->
        [{:credential_ref, "is required"} | errors]

      {:error, {:missing_field, :id}} ->
        [{:credential_ref, "must include id"} | errors]

      {:error, {:missing_field, :owner_user_id}} ->
        [{:credential_ref, "must include owner_user_id"} | errors]

      {:error, {:missing_field, :provider}} ->
        [{:credential_ref, "must include provider"} | errors]

      {:error, {:missing_field, :auth_type}} ->
        [{:credential_ref, "must include auth_type"} | errors]

      {:error, :credential_ref_provider_mismatch} ->
        [{:credential_ref, "must target openai_api_key"} | errors]

      {:error, :credential_ref_auth_type_mismatch} ->
        [{:credential_ref, "must use api_key auth_type"} | errors]

      {:error, _reason} ->
        [{:credential_ref, "is invalid"} | errors]
    end
  end
end
