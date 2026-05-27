defmodule Fizz.Workflows.Compiler.ExpressionCompiler do
  @moduledoc false

  alias Fizz.Fields.Credential
  alias Fizz.Workflows.Expressions
  alias Fizz.Workflows.Expressions.AccessPlan

  @spec compile(map()) :: {:ok, map()} | {:error, [map()]}
  def compile(ir) when is_map(ir) do
    known_step_ids = Map.keys(ir.steps)
    step_name_to_id = step_name_to_id(steps_from_map(ir.steps))

    {steps, errors} =
      Enum.reduce(ir.steps, {%{}, []}, fn {step_id, step}, {compiled_steps, errors} ->
        case compile_step(step, known_step_ids, step_name_to_id) do
          {:ok, compiled_step} ->
            {Map.put(compiled_steps, step_id, compiled_step), errors}

          {:error, step_errors} ->
            {compiled_steps, errors ++ step_errors}
        end
      end)

    case errors do
      [] -> {:ok, %{ir | steps: steps}}
      _ -> {:error, errors}
    end
  end

  @spec validate_step_configs([map()], [String.t()]) :: [map()]
  def validate_step_configs(steps, known_step_ids) when is_list(steps) do
    validate_step_configs_detailed(steps, known_step_ids)
    |> Enum.map(fn error ->
      %{
        message: "step #{error.step_id} #{format_validation_error(error)}",
        step_id: error.step_id
      }
    end)
  end

  @spec validate_step_configs_detailed([map()], [String.t()]) :: [map()]
  def validate_step_configs_detailed(steps, known_step_ids) when is_list(steps) do
    step_name_to_id = step_name_to_id(steps)

    Enum.flat_map(steps, fn step ->
      step.config
      |> validate_tree_detailed(known_step_ids, step_name_to_id, [])
      |> Enum.map(&Map.put(&1, :step_id, step.id))
    end)
  end

  defp compile_step(step, known_step_ids, step_name_to_id) do
    {compiled_config, dependencies, errors} =
      compile_tree(step.config, known_step_ids, step_name_to_id, [], step.id)

    if errors == [] do
      {:ok,
       Map.merge(step, %{
         compiled_config: compiled_config,
         dependencies: %{
           step_ids: dependencies.step_ids |> MapSet.to_list() |> Enum.sort(),
           runtime_keys: dependencies.runtime_keys |> MapSet.to_list() |> Enum.sort()
         }
       })}
    else
      {:error,
       Enum.map(errors, fn error ->
         %{message: "step #{step.id} #{error}", step_id: step.id}
       end)}
    end
  end

  defp compile_tree(
         %{"$credential" => true} = credential_map,
         _known_step_ids,
         _step_name_to_id,
         path,
         step_id
       ) do
    case build_credential_ref(credential_map, step_id) do
      {:ok, ref} ->
        dependencies = %{
          step_ids: MapSet.new(),
          runtime_keys: MapSet.new([:_credential_resolver])
        }

        {ref, dependencies, []}

      {:error, message} ->
        {%AccessPlan.Literal{value: credential_map}, empty_dependencies(),
         [format_path_error(path, message)]}
    end
  end

  defp compile_tree(map, known_step_ids, step_name_to_id, path, step_id) when is_map(map) do
    Enum.reduce(map, {%{}, empty_dependencies(), []}, fn {key, value},
                                                         {acc, dependencies, errors} ->
      {compiled_value, value_dependencies, value_errors} =
        compile_tree(value, known_step_ids, step_name_to_id, path ++ [to_string(key)], step_id)

      {
        Map.put(acc, key, compiled_value),
        merge_dependencies(dependencies, value_dependencies),
        errors ++ value_errors
      }
    end)
  end

  defp compile_tree(list, known_step_ids, step_name_to_id, path, step_id) when is_list(list) do
    {compiled_values, dependencies, errors} =
      Enum.reduce(Enum.with_index(list), {[], empty_dependencies(), []}, fn {value, index},
                                                                            {acc, dependencies,
                                                                             errors} ->
        {compiled_value, value_dependencies, value_errors} =
          compile_tree(
            value,
            known_step_ids,
            step_name_to_id,
            path ++ [Integer.to_string(index)],
            step_id
          )

        {
          [compiled_value | acc],
          merge_dependencies(dependencies, value_dependencies),
          errors ++ value_errors
        }
      end)

    {Enum.reverse(compiled_values), dependencies, errors}
  end

  defp compile_tree(value, known_step_ids, step_name_to_id, path, _step_id)
       when is_binary(value) do
    if expression_string?(value) do
      case Expressions.to_access_plan(value,
             strict_filters: true,
             known_step_ids: known_step_ids,
             step_name_to_id: step_name_to_id
           ) do
        {:ok, plan} ->
          dependencies =
            case plan do
              %{parsed: parsed} -> Expressions.dependencies(parsed)
              _ -> empty_dependencies()
            end

          {plan, dependencies, []}

        {:error, errors} ->
          {%AccessPlan.Literal{value: value}, empty_dependencies(),
           Enum.map(errors, &format_path_error(path, &1))}
      end
    else
      {%AccessPlan.Literal{value: value}, empty_dependencies(), []}
    end
  end

  defp compile_tree(value, _known_step_ids, _step_name_to_id, _path, _step_id) do
    {%AccessPlan.Literal{value: value}, empty_dependencies(), []}
  end

  defp build_credential_ref(credential_map, step_id) do
    with {:ok, %{requirement_key: requirement_key, provider: provider, auth_type: auth_type}} <-
           Credential.normalize(credential_map) do
      {:ok,
       %AccessPlan.CredentialRef{
         requirement_key: requirement_key,
         step_id: step_id,
         provider: provider,
         auth_type: auth_type
       }}
    else
      {:error, {:missing_field, field}} -> {:error, "credential is missing #{field}"}
      {:error, _reason} -> {:error, "credential declaration is invalid"}
    end
  end

  defp validate_tree_detailed(map, known_step_ids, step_name_to_id, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      validate_tree_detailed(value, known_step_ids, step_name_to_id, path ++ [to_string(key)])
    end)
  end

  defp validate_tree_detailed(list, known_step_ids, step_name_to_id, path) when is_list(list) do
    Enum.flat_map(Enum.with_index(list), fn {value, index} ->
      validate_tree_detailed(
        value,
        known_step_ids,
        step_name_to_id,
        path ++ [Integer.to_string(index)]
      )
    end)
  end

  defp validate_tree_detailed(value, known_step_ids, step_name_to_id, path)
       when is_binary(value) do
    if expression_string?(value) do
      case Expressions.validate(value,
             strict_filters: true,
             known_step_ids: known_step_ids,
             step_name_to_id: step_name_to_id
           ) do
        {:ok, _parsed} ->
          []

        {:error, errors} ->
          Enum.map(errors, fn message ->
            %{field: format_field_path(path), message: message}
          end)
      end
    else
      []
    end
  end

  defp validate_tree_detailed(_value, _known_step_ids, _step_name_to_id, _path), do: []

  defp expression_string?(value),
    do: String.contains?(value, "{{") or String.contains?(value, "{%")

  defp format_path_error([], message), do: message
  defp format_path_error(path, message), do: "config.#{Enum.join(path, ".")}: #{message}"

  defp format_validation_error(%{field: nil, message: message}), do: message

  defp format_validation_error(%{field: field, message: message}),
    do: "config.#{field}: #{message}"

  defp format_field_path([]), do: nil
  defp format_field_path(path), do: Enum.join(path, ".")

  defp empty_dependencies do
    %{step_ids: MapSet.new(), runtime_keys: MapSet.new()}
  end

  defp merge_dependencies(left, right) do
    %{
      step_ids: MapSet.union(left.step_ids, right.step_ids),
      runtime_keys: MapSet.union(left.runtime_keys, right.runtime_keys)
    }
  end

  defp steps_from_map(steps) when is_map(steps), do: Map.values(steps)

  defp step_name_to_id(steps) do
    steps
    |> Enum.reduce(%{}, fn step, acc -> put_step_name(acc, step_id(step), step_name(step)) end)
    |> Enum.reject(&match?({_name, :duplicate}, &1))
    |> Map.new()
  end

  defp put_step_name(acc, step_id, step_name)
       when is_binary(step_id) and is_binary(step_name) do
    case String.trim(step_name) do
      "" ->
        acc

      _ ->
        Map.update(acc, step_name, step_id, fn
          ^step_id -> step_id
          _existing_step_id -> :duplicate
        end)
    end
  end

  defp put_step_name(acc, _step_id, _step_name), do: acc

  defp step_id(%{id: step_id}) when is_binary(step_id), do: step_id
  defp step_id(%{"id" => step_id}) when is_binary(step_id), do: step_id
  defp step_id(_step), do: nil

  defp step_name(%{name: step_name}) when is_binary(step_name), do: step_name
  defp step_name(%{"name" => step_name}) when is_binary(step_name), do: step_name
  defp step_name(_step), do: nil
end
