defmodule Fizz.Integrations.Library.Fizz.Builtins.AIAgent do
  @moduledoc """
  AI step that assembles connected model/schema/tool dependencies into a provider payload.

  Connected values are injected by the workflow runtime under:

  - `main` - upstream flow input
  - `model` - output from a node that provides `ai.chat_model`
  - `structured_schema` - optional output from a node that provides `ai.schema`
  - `tools` - zero or more outputs from nodes that provide `ai.tool`

  `mode: "assemble_only"` returns the assembled payload without calling a
  provider.

  `mode: "provider_chat"` delegates to `ChatModelProviders`, which dispatches by
  the connected model's provider-prefixed `model_spec`.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "ai_agent",
    name: "AI Agent",
    category: "AI",
    description: "Assemble AI dependencies into a payload or execute a chat request",
    icon: "hero-bolt",
    kind: :action,
    integration: "fizz"

  @behaviour Fizz.Workflows.StepExecutor

  alias Fizz.Fields
  alias Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders

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

  @input_schema %{
    "type" => "object",
    "required" => ["model"],
    "properties" => %{
      "main" => %{
        "title" => "Input",
        "description" => "Primary flow input",
        "connection" => %{"kind" => "flow"}
      },
      "model" => %{
        "title" => "Model",
        "description" => "LLM model provider",
        "connection" => %{
          "kind" => "dependency",
          "cardinality" => "one",
          "accepts" => %{"provides" => ["ai.chat_model"]}
        }
      },
      "structured_schema" => %{
        "title" => "Structured Schema",
        "description" => "Optional structured response schema",
        "connection" => %{
          "kind" => "dependency",
          "cardinality" => "one",
          "accepts" => %{"provides" => ["ai.schema"]}
        }
      },
      "tools" => %{
        "title" => "Tools",
        "description" => "Optional tool descriptors",
        "type" => "array",
        "items" => %{"type" => "object"},
        "connection" => %{
          "kind" => "dependency",
          "cardinality" => "many",
          "accepts" => %{"provides" => ["ai.tool"]}
        }
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "main" => %{"description" => "Primary flow input"},
      "model" => %{"type" => "object"},
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
         {:ok, messages} <- build_messages(config, slot_value(input, "main")),
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
    tools = normalize_tools(slot_value(input, "tools"))
    primary = slot_value(input, "main")

    if valid_model_config?(model_config) do
      assembled =
        %{
          "main" => primary,
          "model" => model_config,
          "messages" => messages,
          "tools" => tools
        }
        |> maybe_put_structured_schema(structured_schema)

      {:ok, assembled}
    else
      {:error, {:invalid_dependency_output, :model}}
    end
  end

  defp valid_model_config?(%{
         "kind" => "ai.chat_model",
         "credential_ref" => credential_ref,
         "model_spec" => model_spec
       })
       when is_map(credential_ref) and is_binary(model_spec) and model_spec != "",
       do: true

  defp valid_model_config?(_model_config), do: false

  defp run_provider_chat(assembled, ctx) do
    with {:ok, response} <- ChatModelProviders.generate(assembled, ctx) do
      {:ok, Map.put(assembled, "response", provider_response_payload(response))}
    end
  end

  defp provider_response_payload(%ReqLLM.Response{} = response) do
    %{
      "id" => response.id,
      "model" => response.model,
      "ok" => ReqLLM.Response.ok?(response),
      "text" => ReqLLM.Response.text(response),
      "thinking" => blank_to_nil(ReqLLM.Response.thinking(response)),
      "object" => normalize_output_value(response.object),
      "tool_calls" => normalize_output_value(ReqLLM.Response.tool_calls(response)),
      "usage" => normalize_output_value(ReqLLM.Response.usage(response)),
      "finish_reason" => normalize_output_value(ReqLLM.Response.finish_reason(response)),
      "error" => normalize_output_value(response.error)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp provider_response_payload(response), do: normalize_output_value(response)

  defp blank_to_nil(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp normalize_model_config(%{"kind" => "ai.chat_model"} = model_config) do
    model_spec = Map.get(model_config, "model_spec")
    credential_ref = Map.get(model_config, "credential_ref")

    if is_binary(model_spec) and model_spec != "" and is_map(credential_ref) do
      {:ok, model_config}
    else
      {:error, {:invalid_dependency_output, :model}}
    end
  end

  defp normalize_model_config(%{kind: "ai.chat_model"} = model_config) do
    model_spec = Map.get(model_config, :model_spec)
    credential_ref = Map.get(model_config, :credential_ref)

    if is_binary(model_spec) and model_spec != "" and is_map(credential_ref) do
      {:ok,
       %{
         "kind" => "ai.chat_model",
         "provider" => Map.get(model_config, :provider),
         "credential_ref" => credential_ref,
         "model_spec" => model_spec,
         "temperature" => Map.get(model_config, :temperature, 0.2),
         "max_tokens" => Map.get(model_config, :max_tokens, 800),
         "capabilities" => Map.get(model_config, :capabilities, [])
       }}
    else
      {:error, {:invalid_dependency_output, :model}}
    end
  end

  defp normalize_model_config(_), do: {:error, {:invalid_dependency_output, :model}}

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

  defp normalize_structured_schema(%{"kind" => "ai.schema", "schema" => json_schema} = schema)
       when is_map(json_schema) and map_size(json_schema) > 0 do
    {:ok,
     %{
       "kind" => "ai.schema",
       "name" => schema_name(schema),
       "schema" => unwrap_pasted_schema(json_schema),
       "strict" => strict_schema?(schema),
       "response_format" => Map.get(schema, "response_format")
     }}
  end

  defp normalize_structured_schema(%{kind: "ai.schema", schema: json_schema} = schema)
       when is_map(json_schema) and map_size(json_schema) > 0 do
    normalize_structured_schema(%{
      "kind" => "ai.schema",
      "name" => Map.get(schema, :name),
      "schema" => json_schema,
      "strict" => Map.get(schema, :strict, true),
      "response_format" => Map.get(schema, :response_format)
    })
  end

  defp normalize_structured_schema(_schema),
    do: {:error, {:invalid_dependency_output, :structured_schema}}

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

  defp response_format(%{"response_format" => response_format}) when is_map(response_format) do
    response_format
  end

  defp response_format(%{"name" => name, "schema" => json_schema, "strict" => strict}) do
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

  defp normalize_tools(tools) when is_list(tools),
    do: tools |> Enum.reject(&is_nil/1) |> Enum.map(&normalize_tool/1)

  defp normalize_tools(tool) when is_map(tool), do: [normalize_tool(tool)]
  defp normalize_tools(tool), do: [%{"value" => tool}]

  defp normalize_tool(%{kind: "ai.tool"} = tool),
    do: Map.new(tool, fn {key, value} -> {to_string(key), value} end)

  defp normalize_tool(tool), do: tool

  defp normalize_output_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_output_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp normalize_output_value(%_{} = value) do
    value
    |> Map.from_struct()
    |> normalize_output_value()
  end

  defp normalize_output_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), normalize_output_value(nested_value)}
    end)
  end

  defp normalize_output_value(value) when is_list(value) do
    Enum.map(value, &normalize_output_value/1)
  end

  defp normalize_output_value(nil), do: nil

  defp normalize_output_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: value

  defp normalize_output_value(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_output_value(value), do: inspect(value)

  defp slot_value(input, key) when is_map(input) and is_binary(key) do
    case Map.fetch(input, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(input, slot_key_atom(key))
    end
  end

  defp slot_value(_input, _key), do: nil

  defp slot_key_atom("main"), do: :main
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
end
