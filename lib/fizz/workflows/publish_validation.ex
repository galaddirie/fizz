defmodule Fizz.Workflows.PublishValidation do
  @moduledoc false

  alias Fizz.Accounts.Scope
  alias Fizz.Graph
  alias Fizz.Integrations.CredentialRef
  alias Fizz.Integrations.CredentialsResolver
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

  @spec credential_accessibility_issues([map()], Scope.t()) :: [issue()]
  def credential_accessibility_issues(steps, %Scope{} = scope) when is_list(steps) do
    accessible_ids_by_key =
      steps
      |> credential_checks()
      |> Enum.group_by(fn %{credential_ref: credential_ref} ->
        {credential_ref["provider"], credential_ref["auth_type"]}
      end)
      |> Enum.map(fn {key, _checks} -> {key, accessible_credential_ids(scope, key)} end)
      |> Map.new()

    steps
    |> credential_checks()
    |> Enum.flat_map(fn %{step_id: step_id, field: field, credential_ref: credential_ref} ->
      key = {credential_ref["provider"], credential_ref["auth_type"]}
      accessible_ids = Map.get(accessible_ids_by_key, key, MapSet.new())

      if MapSet.member?(accessible_ids, credential_ref["id"]) do
        []
      else
        [
          %{
            step_id: step_id,
            field: field,
            message: "selected credential is not accessible to the current user"
          }
        ]
      end
    end)
  end

  @spec credential_accessibility_issues([map()], term()) :: [issue()]
  def credential_accessibility_issues(_steps, _scope), do: []

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
        type.config_schema
        |> Map.get("required", [])
        |> List.wrap()
        |> Enum.filter(&is_binary/1)

      :error ->
        []
    end
  end

  defp missing_required_value?(nil), do: true
  defp missing_required_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_required_value?(value) when is_list(value), do: value == []
  defp missing_required_value?(_value), do: false

  defp credential_checks(steps) do
    Enum.flat_map(steps, &step_credential_checks/1)
  end

  defp step_credential_checks(step) do
    case step_type(step.type_id) do
      {:ok, %Type{} = type} ->
        type.config_schema
        |> Map.get("properties", %{})
        |> Enum.flat_map(fn {field, property} ->
          credential_check(step, field, property)
        end)

      :error ->
        []
    end
  end

  defp credential_check(step, field, property) when is_binary(field) and is_map(property) do
    if credential_field?(field, property) do
      case CredentialRef.normalize(Map.get(step.config || %{}, field)) do
        {:ok, credential_ref} ->
          [
            %{
              step_id: step.id,
              field: field,
              credential_ref: credential_ref
            }
          ]

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end

  defp credential_check(_step, _field, _property), do: []

  defp credential_field?(field, property) do
    field == "credential_ref" or
      String.ends_with?(field, "_credential_ref") or
      get_in(property, ["ui", "resolver"]) == CredentialsResolver
  end

  defp accessible_credential_ids(scope, {provider, auth_type})
       when is_binary(provider) and is_binary(auth_type) do
    case CredentialsResolver.resolve(%{
           q: "",
           params: %{
             "provider_filter" => [provider],
             "auth_types" => [auth_type]
           },
           context: %{current_scope: scope}
         }) do
      {:ok, options} ->
        options
        |> Enum.map(&Map.get(&1, "id"))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      {:error, _reason} ->
        MapSet.new()
    end
  end

  defp accessible_credential_ids(_scope, _key), do: MapSet.new()
end
