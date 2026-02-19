defmodule Fizz.Steps.Executors.AIAgent do
  @moduledoc """
  Root AI agent node that consumes typed sub-node slots.

  Sub-node outputs are injected by `Fizz.Runtime.Steps.StepRunner` under:

  - `_primary` - Primary flow input
  - `model` - Output from `openai_model` or `anthropic_model`
  - `prompt` - Output from `ai_prompt_template`
  - `tools` - List of outputs from `ai_tool_http`
  """

  use Fizz.Steps.Definition,
    id: "ai_agent",
    name: "AI Agent",
    category: "AI",
    description: "Compose model/prompt/tool sub-nodes and run an AI request",
    icon: "hero-bolt",
    kind: :action,
    role: :root

  alias Fizz.Accounts.Scope
  alias Fizz.Integrations.Providers.OpenAIApiKey
  alias Fizz.Runtime.ExecutionContext

  @behaviour Fizz.Steps.Executors.Behaviour

  @subnode_slots [
    %{
      "id" => "model",
      "title" => "Model",
      "description" => "LLM model config provider",
      "required" => true,
      "cardinality" => "one",
      "accepts" => %{"type_ids" => ["openai_model", "anthropic_model"]},
      "input_key" => "model"
    },
    %{
      "id" => "prompt",
      "title" => "Prompt",
      "description" => "Prompt/message builder",
      "required" => true,
      "cardinality" => "one",
      "accepts" => %{"type_ids" => ["ai_prompt_template"]},
      "input_key" => "prompt"
    },
    %{
      "id" => "tools",
      "title" => "Tools",
      "description" => "Optional tool descriptors",
      "required" => false,
      "cardinality" => "many",
      "accepts" => %{"type_ids" => ["ai_tool_http"]},
      "input_key" => "tools"
    }
  ]

  @default_config %{
    "mode" => "assemble_only"
  }

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "mode" => %{
        "type" => "string",
        "title" => "Execution Mode",
        "enum" => ["assemble_only", "provider_chat"],
        "default" => "assemble_only",
        "description" => "Assemble payload only or call provider integrations"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "_primary" => %{"description" => "Primary flow input"},
      "provider" => %{"type" => "string"},
      "model" => %{"type" => "string"},
      "temperature" => %{"type" => "number"},
      "max_tokens" => %{"type" => "integer"},
      "messages" => %{"type" => "array"},
      "tools" => %{"type" => "array"},
      "response" => %{"description" => "Provider response (provider_chat mode only)"}
    }
  }

  @impl true
  def default_config, do: @default_config

  @impl true
  def execute(config, input, %ExecutionContext{} = ctx) do
    with {:ok, model_config} <- normalize_model_config(slot_value(input, "model")),
         {:ok, messages} <-
           normalize_messages(slot_value(input, "prompt"), slot_value(input, "_primary")),
         {:ok, assembled} <- build_output(input, model_config, messages) do
      case Map.get(config, "mode", "assemble_only") do
        "provider_chat" ->
          run_provider_chat(assembled, ctx)

        _ ->
          {:ok, assembled}
      end
    end
  end

  @impl true
  def execute(config, input, _ctx), do: execute(config, input, %ExecutionContext{})

  @impl true
  def validate_config(config) do
    case Map.get(config, "mode", "assemble_only") do
      mode when mode in ["assemble_only", "provider_chat"] ->
        :ok

      _ ->
        {:error, [mode: "must be assemble_only or provider_chat"]}
    end
  end

  defp build_output(input, model_config, messages) do
    provider = Map.get(model_config, "provider", "openai_api_key")
    model = Map.get(model_config, "model")
    temperature = Map.get(model_config, "temperature", 0.2)
    max_tokens = Map.get(model_config, "max_tokens", 800)
    tools = normalize_tools(slot_value(input, "tools"))
    primary = slot_value(input, "_primary")

    if is_binary(model) and model != "" do
      {:ok,
       %{
         "_primary" => primary,
         "provider" => provider,
         "model" => model,
         "temperature" => temperature,
         "max_tokens" => max_tokens,
         "messages" => messages,
         "tools" => tools
       }}
    else
      {:error, {:invalid_subnode_output, :model}}
    end
  end

  defp run_provider_chat(assembled, ctx) do
    with {:ok, scope, organization_id} <- scope_and_organization(ctx),
         {:ok, response} <- generate_provider_response(scope, organization_id, assembled) do
      {:ok, Map.put(assembled, "response", response)}
    end
  end

  defp generate_provider_response(scope, organization_id, assembled) do
    case assembled["provider"] do
      "openai_api_key" ->
        OpenAIApiKey.generate_text(
          scope,
          organization_id,
          assembled["model"],
          assembled["messages"],
          generation_opts(assembled)
        )

      "anthropic_api_key" ->
        {:error, :anthropic_chat_not_implemented}

      provider when is_binary(provider) ->
        {:error, {:unsupported_provider, provider}}

      _ ->
        {:error, :missing_provider}
    end
  end

  defp generation_opts(assembled) do
    []
    |> maybe_put_opt(:temperature, assembled["temperature"])
    |> maybe_put_opt(:max_tokens, assembled["max_tokens"])
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_model_config(%{"model" => model} = model_config) when is_binary(model) do
    {:ok, model_config}
  end

  defp normalize_model_config(%{model: model} = model_config) when is_binary(model) do
    {:ok,
     %{
       "provider" => Map.get(model_config, :provider, "openai_api_key"),
       "model" => model,
       "temperature" => Map.get(model_config, :temperature, 0.2),
       "max_tokens" => Map.get(model_config, :max_tokens, 800)
     }}
  end

  defp normalize_model_config(model) when is_binary(model) do
    {:ok,
     %{
       "provider" => "openai_api_key",
       "model" => model,
       "temperature" => 0.2,
       "max_tokens" => 800
     }}
  end

  defp normalize_model_config(_), do: {:error, {:invalid_subnode_output, :model}}

  defp normalize_messages(%{"messages" => messages}, _primary) when is_list(messages) do
    {:ok, messages}
  end

  defp normalize_messages(%{messages: messages}, _primary) when is_list(messages) do
    {:ok, messages}
  end

  defp normalize_messages(prompt, _primary) when is_binary(prompt) do
    {:ok, [%{"role" => "user", "content" => prompt}]}
  end

  defp normalize_messages(_prompt, primary) do
    case prompt_from_primary(primary) do
      nil -> {:error, {:invalid_subnode_output, :prompt}}
      prompt -> {:ok, [%{"role" => "user", "content" => prompt}]}
    end
  end

  defp prompt_from_primary(nil), do: nil
  defp prompt_from_primary(prompt) when is_binary(prompt), do: prompt
  defp prompt_from_primary(prompt) when is_number(prompt), do: to_string(prompt)
  defp prompt_from_primary(prompt) when is_boolean(prompt), do: to_string(prompt)
  defp prompt_from_primary(prompt), do: Jason.encode!(prompt)

  defp normalize_tools(nil), do: []
  defp normalize_tools(tools) when is_list(tools), do: Enum.reject(tools, &is_nil/1)
  defp normalize_tools(tool) when is_map(tool), do: [tool]
  defp normalize_tools(tool), do: [%{"value" => tool}]

  defp slot_value(input, key) when is_map(input) and is_binary(key) do
    case Map.fetch(input, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(input, slot_key_atom(key))
    end
  end

  defp slot_value(_input, _key), do: nil

  defp slot_key_atom("_primary"), do: :_primary
  defp slot_key_atom("model"), do: :model
  defp slot_key_atom("prompt"), do: :prompt
  defp slot_key_atom("tools"), do: :tools
  defp slot_key_atom(_key), do: nil

  defp scope_and_organization(%ExecutionContext{metadata: metadata}) when is_map(metadata) do
    scope = Map.get(metadata, :scope) || Map.get(metadata, "scope")

    case scope do
      %Scope{organization_id: organization_id} = scope
      when is_binary(organization_id) and byte_size(organization_id) > 0 ->
        {:ok, scope, organization_id}

      %Scope{} ->
        {:error, :organization_scope_required}

      _ ->
        {:error, :scope_not_available}
    end
  end

  defp scope_and_organization(_), do: {:error, :scope_not_available}
end
