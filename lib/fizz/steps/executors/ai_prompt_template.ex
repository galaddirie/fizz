defmodule Fizz.Steps.Executors.AIPromptTemplate do
  @moduledoc """
  Produces chat-style messages for AI agent steps.
  """

  use Fizz.Steps.Definition,
    id: "ai_prompt_template",
    name: "AI Prompt Template",
    category: "AI",
    description: "Build chat messages from system/user prompt templates",
    icon: "hero-document-text",
    kind: :transform,
    role: :subnode

  @behaviour Fizz.Steps.Executors.Behaviour

  @default_config %{
    "system_prompt" => "You are a helpful assistant.",
    "user_prompt" => "{{ json }}",
    "context" => %{}
  }

  @config_schema %{
    "type" => "object",
    "required" => ["user_prompt"],
    "properties" => %{
      "system_prompt" => %{
        "type" => "string",
        "title" => "System Prompt",
        "description" => "Optional system message"
      },
      "user_prompt" => %{
        "type" => "string",
        "title" => "User Prompt",
        "description" => "User message template"
      },
      "context" => %{
        "title" => "Context",
        "description" => "Map used for {{key}} interpolation"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "messages" => %{"type" => "array"},
      "system_prompt" => %{"type" => "string"},
      "user_prompt" => %{"type" => "string"}
    }
  }

  @impl true
  def default_config, do: @default_config

  @impl true
  def execute(config, _input, _ctx) do
    system_prompt = Map.get(config, "system_prompt")
    user_prompt_template = Map.get(config, "user_prompt", "")
    context = Map.get(config, "context", %{})
    user_prompt = interpolate_prompt(user_prompt_template, context)

    messages =
      []
      |> maybe_append_message("system", system_prompt)
      |> maybe_append_message("user", user_prompt)

    {:ok,
     %{
       "messages" => messages,
       "system_prompt" => system_prompt,
       "user_prompt" => user_prompt
     }}
  end

  @impl true
  def validate_config(config) do
    case Map.get(config, "user_prompt") do
      prompt when is_binary(prompt) ->
        if String.trim(prompt) == "" do
          {:error, [user_prompt: "is required"]}
        else
          :ok
        end

      _ ->
        {:error, [user_prompt: "is required"]}
    end
  end

  defp maybe_append_message(messages, _role, prompt) when prompt in [nil, ""], do: messages

  defp maybe_append_message(messages, role, prompt) when is_binary(prompt) do
    messages ++ [%{"role" => role, "content" => prompt}]
  end

  defp maybe_append_message(messages, _role, _prompt), do: messages

  defp interpolate_prompt(prompt, context) when is_binary(prompt) and is_map(context) do
    Regex.replace(~r/\{\{\s*([a-zA-Z0-9_\.]+)\s*\}\}/, prompt, fn _, path ->
      context
      |> get_path(String.split(path, "."))
      |> to_prompt_value()
    end)
  end

  defp interpolate_prompt(prompt, _context) when is_binary(prompt), do: prompt
  defp interpolate_prompt(_prompt, _context), do: ""

  defp get_path(value, []), do: value

  defp get_path(value, [segment | rest]) when is_map(value) do
    value
    |> Map.get(segment)
    |> get_path(rest)
  end

  defp get_path(_value, _rest), do: nil

  defp to_prompt_value(nil), do: ""
  defp to_prompt_value(value) when is_binary(value), do: value
  defp to_prompt_value(value) when is_number(value), do: to_string(value)
  defp to_prompt_value(value) when is_boolean(value), do: to_string(value)
  defp to_prompt_value(value), do: Jason.encode!(value)
end
