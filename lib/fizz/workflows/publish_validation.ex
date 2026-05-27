defmodule Fizz.Workflows.PublishValidation do
  @moduledoc false

  alias Fizz.Graph
  alias Fizz.Fields.Credential
  alias Fizz.Steps.Executors.Behaviour, as: StepExecutorBehaviour
  alias Fizz.Steps.Registry
  alias Fizz.Steps.Type
  alias Fizz.Workflows.Compiler.ExpressionCompiler

  @type issue :: %{
          step_id: String.t() | nil,
          field: String.t() | nil,
          message: String.t()
        }

  @spec has_entry_step_issues([map()], [map()]) :: [issue()]
  def has_entry_step_issues(steps, connections) when is_list(steps) and is_list(connections) do
    case Graph.from_workflow(steps, connections) do
      {:ok, graph} ->
        case Graph.roots(graph) do
          [] -> [%{step_id: nil, field: nil, message: has_entry_step_message()}]
          _entry_steps -> []
        end

      {:error, _reason} ->
        []
    end
  end

  @spec step_config_issues([map()]) :: [issue()]
  def step_config_issues(steps) when is_list(steps) do
    Enum.flat_map(steps, fn step ->
      case StepExecutorBehaviour.validate_config(step.type_id, step.config || %{}) do
        :ok ->
          []

        {:error, errors} ->
          errors
          |> List.wrap()
          |> Enum.map(&step_config_issue(step.id, &1))
      end
    end)
  end

  @spec expression_issues([map()]) :: [issue()]
  def expression_issues(steps) when is_list(steps) do
    known_step_ids = Enum.map(steps, & &1.id)

    ExpressionCompiler.validate_step_configs_detailed(steps, known_step_ids)
    |> Enum.map(fn error ->
      %{
        step_id: error.step_id,
        field: error.field,
        message: error.message
      }
    end)
  end

  @doc """
  Validates that credential declarations in step configs are well-formed.

  This replaces the prior credential-accessibility check. Per-user credential
  selection now happens at run time via `Fizz.Workflows.Readiness`, so publish
  validation only needs to confirm the workflow declares its credential
  requirements correctly.
  """
  @spec credential_declaration_issues([map()]) :: [issue()]
  def credential_declaration_issues(steps) when is_list(steps) do
    Enum.flat_map(steps, fn step ->
      config = step.config || %{}

      required_credential_declaration_issues(step, config) ++
        configured_credential_declaration_issues(step, config)
    end)
  end

  @spec trigger_root_issues([map()], [map()]) :: [issue()]
  def trigger_root_issues(steps, connections) when is_list(steps) and is_list(connections) do
    incoming_step_ids =
      connections
      |> Enum.map(& &1.target_step_id)
      |> MapSet.new()

    steps
    |> Enum.flat_map(fn step ->
      case step_type(step.type_id) do
        {:ok, %Type{} = type} ->
          if Type.trigger?(type) and MapSet.member?(incoming_step_ids, step.id) do
            [%{step_id: step.id, field: nil, message: trigger_root_message()}]
          else
            []
          end

        :error ->
          []
      end
    end)
  end

  @spec cycle_issues([map()], [map()]) :: [issue()]
  def cycle_issues(steps, connections) when is_list(steps) and is_list(connections) do
    case Graph.from_workflow(steps, connections) do
      {:ok, graph} ->
        case Graph.topological_sort(graph) do
          {:ok, _sorted_step_ids} ->
            []

          {:error, {:cycle_detected, step_ids}} ->
            [%{step_id: nil, field: nil, message: cycle_message(step_ids)}]
        end

      {:error, {:invalid_edges, _invalid_edges}} ->
        []
    end
  end

  @spec required_field_issues([map()]) :: [issue()]
  def required_field_issues(steps) when is_list(steps) do
    Enum.flat_map(steps, fn step ->
      required_fields_for_step(step.type_id)
      |> Enum.flat_map(fn field ->
        if missing_required_value?(Map.get(step.config || %{}, field)) do
          [%{step_id: step.id, field: field, message: "is required"}]
        else
          []
        end
      end)
    end)
  end

  @spec has_entry_step_message() :: String.t()
  def has_entry_step_message, do: "must include at least one entry step"

  @spec trigger_root_message() :: String.t()
  def trigger_root_message, do: "trigger steps must be graph roots with no incoming connections"

  @spec cycle_message([String.t()]) :: String.t()
  def cycle_message(step_ids) when is_list(step_ids) do
    "creates a cycle involving steps: #{Enum.join(Enum.sort(step_ids), ", ")}"
  end

  @spec format_step_config_issue(issue()) :: String.t()
  def format_step_config_issue(%{field: nil, message: message}), do: message
  def format_step_config_issue(%{field: field, message: message}), do: "#{field} #{message}"

  @spec format_expression_issue(issue()) :: String.t()
  def format_expression_issue(%{field: nil, message: message}), do: message

  def format_expression_issue(%{field: field, message: message}),
    do: "config.#{field}: #{message}"

  defp step_config_issue(step_id, {field, message}) do
    %{
      step_id: step_id,
      field: field_to_string(field),
      message: to_string(message)
    }
  end

  defp step_config_issue(step_id, error) do
    %{
      step_id: step_id,
      field: nil,
      message: inspect(error)
    }
  end

  defp field_to_string(field) when is_atom(field), do: Atom.to_string(field)
  defp field_to_string(field) when is_binary(field), do: field
  defp field_to_string(_field), do: nil

  defp step_type(type_id) when is_binary(type_id) do
    case Registry.get(type_id) do
      {:ok, type} -> {:ok, type}
      {:error, :not_found} -> :error
    end
  end

  defp step_type(_type_id), do: :error

  defp required_fields_for_step(type_id) do
    case step_type(type_id) do
      {:ok, %Type{} = type} ->
        config_schema = type.config_schema
        properties = schema_properties(config_schema)

        config_schema
        |> schema_required_fields()
        |> Enum.reject(fn field -> credential_schema_property?(Map.get(properties, field)) end)

      :error ->
        []
    end
  end

  defp required_credential_fields_for_step(type_id) do
    case step_type(type_id) do
      {:ok, %Type{} = type} ->
        type.config_schema
        |> schema_properties()
        |> Enum.flat_map(fn
          {field, property} when is_binary(field) ->
            case credential_schema_property?(property) do
              true -> [field]
              false -> []
            end

          _property ->
            []
        end)

      :error ->
        []
    end
  end

  defp configured_credential_declaration_issues(step, config) do
    config
    |> Credential.walk()
    |> Enum.flat_map(fn %{path: path, declaration: declaration} ->
      case Credential.validate(declaration) do
        :ok ->
          []

        {:error, message} ->
          [%{step_id: step.id, field: Credential.format_path(path), message: message}]
      end
    end)
  end

  defp required_credential_declaration_issues(step, config) do
    step.type_id
    |> required_credential_fields_for_step()
    |> Enum.flat_map(fn field ->
      case Map.fetch(config, field) do
        {:ok, value} -> required_credential_value_issues(step, field, value)
        :error -> [%{step_id: step.id, field: field, message: "is required"}]
      end
    end)
  end

  defp required_credential_value_issues(step, field, value) do
    case Credential.declaration?(value) do
      true ->
        []

      false ->
        [%{step_id: step.id, field: field, message: required_credential_message(value)}]
    end
  end

  defp required_credential_message(value) do
    case missing_required_value?(value) do
      true -> "is required"
      false -> "must be a credential declaration"
    end
  end

  defp schema_required_fields(%{"required" => required}) do
    required
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp schema_required_fields(%{required: required}) do
    required
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp schema_required_fields(_schema), do: []

  defp schema_properties(%{"properties" => properties}) when is_map(properties), do: properties
  defp schema_properties(%{properties: properties}) when is_map(properties), do: properties
  defp schema_properties(_schema), do: %{}

  defp credential_schema_property?(property) when is_map(property) do
    property
    |> property_ui()
    |> ui_component()
    |> Kernel.==("credential")
  end

  defp credential_schema_property?(_property), do: false

  defp property_ui(%{"ui" => ui}) when is_map(ui), do: ui
  defp property_ui(%{ui: ui}) when is_map(ui), do: ui
  defp property_ui(_property), do: %{}

  defp ui_component(%{"component" => component}), do: component
  defp ui_component(%{component: component}), do: component
  defp ui_component(_ui), do: nil

  defp missing_required_value?(nil), do: true
  defp missing_required_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_required_value?(value) when is_list(value), do: value == []
  defp missing_required_value?(_value), do: false
end
