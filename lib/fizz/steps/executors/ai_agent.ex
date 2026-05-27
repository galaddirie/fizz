defmodule Fizz.Steps.Executors.AIAgent do
  @moduledoc """
  Root AI step that assembles typed subnode outputs into a provider payload.

  Subnode outputs are injected by the workflow runtime under:

  - `_primary` - upstream flow input
  - `model` - output from `openai_model` or `anthropic_model`
  - `structured_schema` - optional output from `ai_structure_schema`
  - `tools` - zero or more outputs from `ai_tool_http`

  `mode: "assemble_only"` returns the assembled payload without calling a
  provider.

  `mode: "provider_chat"` calls `OpenAIApiKey.generate_text/5` for OpenAI text
  responses, or `OpenAIApiKey.generate_object/6` when a structured schema is
  connected. Anthropic execution still returns
  `{:error, :anthropic_chat_not_implemented}`. Tool descriptors are included in
  the assembled output, but they are not forwarded to the provider call yet.
  """

  use Fizz.Steps.Definition,
    id: "ai_agent",
    name: "AI Agent",
    category: "AI",
    description: "Assemble AI subnodes into a payload or execute an OpenAI chat request",
    icon: "hero-bolt",
    kind: :action,
    role: :root

  alias Fizz.Accounts.Scope
  alias Fizz.Integrations.Providers.OpenAIApiKey

  @behaviour Fizz.Steps.Executor

  @subnode_inputs [
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
      "id" => "structured_schema",
      "title" => "Structured Schema",
      "description" => "Optional structured response schema",
      "required" => false,
      "cardinality" => "one",
      "accepts" => %{"type_ids" => ["ai_structure_schema"]},
      "input_key" => "structured_schema"
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

  alias Fizz.Fields

  @fields [
    Fields.select("mode",
      label: "Execution Mode",
      default: "assemble_only",
      description: "Assemble payload only or call provider integrations",
      options: Fields.options(~w(assemble_only provider_chat))
    ),
    Fields.string("system_prompt",
      label: "System Prompt",
      format: "textarea",
      default: "You are a helpful assistant.",
      description: "Optional system instruction sent before the user message"
    ),
    Fields.string("user_message",
      label: "User Message",
      format: "textarea",
      required?: true,
      default: "{{ json }}",
      description: "User message template resolved against the primary input"
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "_primary" => %{"description" => "Primary flow input"},
      "provider" => %{"type" => "string"},
      "credential_ref" => %{"type" => "object"},
      "model" => %{"type" => "string"},
      "temperature" => %{"type" => "number"},
      "max_tokens" => %{"type" => "integer"},
      "messages" => %{"type" => "array"},
      "tools" => %{"type" => "array"},
      "structured_schema" => %{"type" => "object"},
      "response_format" => %{"type" => "object"},
      "response" => %{"description" => "Provider response (provider_chat mode only)"}
    }
  }

  @impl true
  def execute(config, input, ctx) when is_map(ctx) do
    with {:ok, model_config} <- normalize_model_config(slot_value(input, "model")),
         {:ok, messages} <- build_messages(config, slot_value(input, "_primary")),
         {:ok, structured_schema} <-
           normalize_structured_schema(slot_value(input, "structured_schema")),
         {:ok, assembled} <- build_output(input, model_config, messages, structured_schema) do
      case Map.get(config, "mode", "assemble_only") do
        "provider_chat" ->
          run_provider_chat(assembled, ctx)

        _ ->
          {:ok, assembled}
      end
    end
  end

  @impl true
  def execute(config, input, _ctx), do: execute(config, input, %{})

  @impl true
  def validate_config(config) do
    errors = []

    errors =
      case Map.get(config, "mode", "assemble_only") do
        mode when mode in ["assemble_only", "provider_chat"] ->
          errors

        _ ->
          [{:mode, "must be assemble_only or provider_chat"} | errors]
      end

    errors = validate_required_message(config, errors)
    errors = validate_optional_prompt(config, "system_prompt", errors)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp build_output(input, model_config, messages, structured_schema) do
    provider = Map.get(model_config, "provider", "openai_api_key")
    credential_ref = Map.get(model_config, "credential_ref")
    model = Map.get(model_config, "model")
    temperature = Map.get(model_config, "temperature", 0.2)
    max_tokens = Map.get(model_config, "max_tokens", 800)
    tools = normalize_tools(slot_value(input, "tools"))
    primary = slot_value(input, "_primary")

    if is_binary(model) and model != "" and is_map(credential_ref) do
      assembled =
        %{
          "_primary" => primary,
          "provider" => provider,
          "credential_ref" => credential_ref,
          "model" => model,
          "temperature" => temperature,
          "max_tokens" => max_tokens,
          "messages" => messages,
          "tools" => tools
        }
        |> maybe_put_structured_schema(structured_schema)

      {:ok, assembled}
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
        generate_openai_response(scope, organization_id, assembled)

      "anthropic_api_key" ->
        {:error, :anthropic_chat_not_implemented}

      provider when is_binary(provider) ->
        {:error, {:unsupported_provider, provider}}

      _ ->
        {:error, :missing_provider}
    end
  end

  defp generate_openai_response(
         scope,
         organization_id,
         %{"structured_schema" => structured_schema} = assembled
       ) do
    OpenAIApiKey.generate_object(
      scope,
      organization_id,
      assembled["model"],
      assembled["messages"],
      Map.fetch!(structured_schema, "json_schema"),
      generation_opts(assembled)
    )
    |> normalize_provider_error(assembled["model"])
  end

  defp generate_openai_response(scope, organization_id, assembled) do
    OpenAIApiKey.generate_text(
      scope,
      organization_id,
      assembled["model"],
      assembled["messages"],
      generation_opts(assembled)
    )
    |> normalize_provider_error(assembled["model"])
  end

  defp normalize_provider_error({:error, :not_found}, model) when is_binary(model) do
    {:error, {:model_not_found, model}}
  end

  defp normalize_provider_error(result, _model), do: result

  defp generation_opts(assembled) do
    []
    |> maybe_put_opt(:temperature, assembled["temperature"])
    |> maybe_put_opt(:max_tokens, assembled["max_tokens"])
    |> maybe_put_opt(:credential_ref, assembled["credential_ref"])
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_model_config(%{"model" => model} = model_config) when is_binary(model) do
    if is_map(Map.get(model_config, "credential_ref")) do
      {:ok, model_config}
    else
      {:error, {:invalid_subnode_output, :model}}
    end
  end

  defp normalize_model_config(%{model: model} = model_config) when is_binary(model) do
    credential_ref = Map.get(model_config, :credential_ref)

    if is_map(credential_ref) do
      {:ok,
       %{
         "provider" => Map.get(model_config, :provider, "openai_api_key"),
         "credential_ref" => credential_ref,
         "model" => model,
         "temperature" => Map.get(model_config, :temperature, 0.2),
         "max_tokens" => Map.get(model_config, :max_tokens, 800)
       }}
    else
      {:error, {:invalid_subnode_output, :model}}
    end
  end

  defp normalize_model_config(model) when is_binary(model) do
    {:error, {:invalid_subnode_output, :model}}
  end

  defp normalize_model_config(_), do: {:error, {:invalid_subnode_output, :model}}

  defp build_messages(config, primary) do
    messages =
      []
      |> maybe_append_message("system", config_value(config, "system_prompt"))
      |> maybe_append_message("user", user_message(config, primary))

    case Enum.any?(messages, &match?(%{"role" => "user"}, &1)) do
      true -> {:ok, messages}
      false -> {:error, {:invalid_config, :user_message}}
    end
  end

  defp user_message(config, primary) do
    config_value(config, "user_message") ||
      config_value(config, "user_prompt") ||
      prompt_from_primary(primary)
  end

  defp maybe_append_message(messages, _role, prompt) when prompt in [nil, ""], do: messages

  defp maybe_append_message(messages, role, prompt) do
    content = to_prompt_value(prompt)

    case String.trim(content) do
      "" -> messages
      _ -> messages ++ [%{"role" => role, "content" => content}]
    end
  end

  defp normalize_structured_schema(nil), do: {:ok, nil}

  defp normalize_structured_schema(%{"json_schema" => json_schema} = schema)
       when is_map(json_schema) and map_size(json_schema) > 0 do
    {:ok,
     %{
       "name" => schema_name(schema),
       "json_schema" => unwrap_pasted_schema(json_schema),
       "strict" => strict_schema?(schema)
     }}
  end

  defp normalize_structured_schema(%{json_schema: json_schema} = schema)
       when is_map(json_schema) and map_size(json_schema) > 0 do
    normalize_structured_schema(%{
      "name" => Map.get(schema, :name),
      "json_schema" => json_schema,
      "strict" => Map.get(schema, :strict, true)
    })
  end

  defp normalize_structured_schema(_schema),
    do: {:error, {:invalid_subnode_output, :structured_schema}}

  defp unwrap_pasted_schema(%{"json_schema" => json_schema} = schema)
       when is_map(json_schema) and map_size(json_schema) > 0 do
    if schema_wrapper?(schema, json_schema) do
      unwrap_pasted_schema(json_schema)
    else
      schema
    end
  end

  defp unwrap_pasted_schema(schema), do: schema

  defp schema_wrapper?(schema, json_schema) do
    not Map.has_key?(schema, "type") and Map.has_key?(json_schema, "type") and
      Enum.any?(["name", "strict"], &Map.has_key?(schema, &1))
  end

  defp prompt_from_primary(nil), do: nil

  defp prompt_from_primary(primary), do: to_prompt_value(primary)

  defp maybe_put_structured_schema(output, nil), do: output

  defp maybe_put_structured_schema(output, structured_schema) do
    response_format = response_format(structured_schema)

    output
    |> Map.put("structured_schema", structured_schema)
    |> Map.put("response_format", response_format)
  end

  defp response_format(%{"name" => name, "json_schema" => json_schema, "strict" => strict}) do
    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => name,
        "schema" => json_schema,
        "strict" => strict
      }
    }
  end

  defp schema_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> "structured_response"
      trimmed_name -> trimmed_name
    end
  end

  defp schema_name(_schema), do: "structured_response"

  defp strict_schema?(%{"strict" => strict}) when strict in [true, false], do: strict
  defp strict_schema?(_schema), do: true

  defp to_prompt_value(value) when is_binary(value), do: value
  defp to_prompt_value(value) when is_number(value), do: to_string(value)
  defp to_prompt_value(value) when is_boolean(value), do: to_string(value)
  defp to_prompt_value(value), do: Jason.encode!(value)

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
  defp slot_key_atom("structured_schema"), do: :structured_schema
  defp slot_key_atom("tools"), do: :tools
  defp slot_key_atom(_key), do: nil

  defp config_value(config, "system_prompt") when is_map(config),
    do: Map.get(config, "system_prompt") || Map.get(config, :system_prompt)

  defp config_value(config, "user_message") when is_map(config),
    do: Map.get(config, "user_message") || Map.get(config, :user_message)

  defp config_value(config, "user_prompt") when is_map(config),
    do: Map.get(config, "user_prompt") || Map.get(config, :user_prompt)

  defp validate_required_message(config, errors) do
    case config_value(config, "user_message") do
      message when is_binary(message) ->
        if String.trim(message) == "" do
          [{:user_message, "is required"} | errors]
        else
          errors
        end

      _ ->
        [{:user_message, "is required"} | errors]
    end
  end

  defp validate_optional_prompt(config, field, errors) do
    case config_value(config, field) do
      nil -> errors
      prompt when is_binary(prompt) -> errors
      _ -> [{config_error_key(field), "must be a string"} | errors]
    end
  end

  defp config_error_key("system_prompt"), do: :system_prompt

  defp scope_and_organization(ctx) when is_map(ctx) do
    with {:ok, scope} <- scope_from_context(ctx),
         {:ok, organization_id} <- organization_from_scope(scope) do
      {:ok, scope, organization_id}
    end
  end

  defp scope_and_organization(_), do: {:error, :scope_not_available}

  defp scope_from_context(ctx) when is_map(ctx) do
    metadata = Map.get(ctx, :metadata) || Map.get(ctx, "metadata")

    scope =
      Map.get(ctx, :scope) ||
        Map.get(ctx, "scope") ||
        Map.get(ctx, :current_scope) ||
        Map.get(ctx, "current_scope") ||
        if(is_map(metadata), do: Map.get(metadata, :scope) || Map.get(metadata, "scope"))

    case scope do
      %Scope{} = scope -> {:ok, scope}
      _ -> {:error, :scope_not_available}
    end
  end

  defp scope_from_context(_), do: {:error, :scope_not_available}

  defp organization_from_scope(%Scope{organization_id: organization_id} = _scope)
       when is_binary(organization_id) and byte_size(organization_id) > 0,
       do: {:ok, organization_id}

  defp organization_from_scope(%Scope{project: %{workos_organization_id: organization_id}})
       when is_binary(organization_id) and byte_size(organization_id) > 0,
       do: {:ok, organization_id}

  defp organization_from_scope(%Scope{}), do: {:error, :organization_scope_required}
end
