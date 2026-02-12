defmodule Fizz.Steps.Executors.Format do
  @moduledoc """
  Executor for Format steps.

  Formats a string using a template and configured data.

  ## Configuration

  - `template` (required) - The template string. Use {{key}} for placeholders.
    Example: "Hello {{user.name}}, your order {{order_id}} is ready."
  - `data` (optional) - Data object used for placeholder replacement. Supports expressions like `{{ json }}`.
  """

  use Fizz.Steps.Definition,
    id: "format",
    name: "Format String",
    category: "Data",
    description: "Format a string using a template with placeholders",
    icon: "hero-document-text",
    kind: :transform

  @config_schema %{
    "type" => "object",
    "required" => ["template"],
    "properties" => %{
      "template" => %{
        "type" => "string",
        "title" => "Template",
        "description" =>
          "Template string with {{field}} placeholders. Supports nested paths like {{user.name}}"
      },
      "data" => %{
        "title" => "Data",
        "description" => "Data object used for placeholder replacement (supports expressions)"
      }
    }
  }

  @input_schema %{
    "description" => "Populates {{ json }} for expressions"
  }

  @output_schema %{
    "type" => "string",
    "description" => "The formatted string"
  }

  @behaviour Fizz.Steps.Executors.Behaviour

  @impl true
  def execute(config, _input, _execution) do
    template = config |> Map.fetch!("template") |> to_string_safe()
    data = Map.get(config, "data", %{})

    result = render_template(template, data)
    {:ok, result}
  end

  @impl true
  def validate_config(config) do
    if Map.get(config, "template") do
      :ok
    else
      {:error, [template: "is required"]}
    end
  end

  defp render_template(template, data) when is_map(data) do
    Regex.replace(~r/\{\{([\w\.]+)\}\}/, template, fn _, key ->
      case get_nested(data, key) do
        nil -> ""
        val -> to_string(val)
      end
    end)
  end

  defp render_template(template, _data), do: template

  defp to_string_safe(nil), do: ""
  defp to_string_safe(text) when is_binary(text), do: text
  defp to_string_safe(text) when is_number(text), do: to_string(text)
  defp to_string_safe(%{"value" => value}), do: to_string_safe(value)
  defp to_string_safe(other), do: inspect(other)

  defp get_nested(map, path) do
    path
    |> String.split(".")
    |> Enum.reduce(map, fn
      key, acc when is_map(acc) -> Map.get(acc, key)
      _key, _acc -> nil
    end)
  end
end
