defmodule FizzWeb.WorkflowLive.Edit.ExpressionPreview do
  @moduledoc false

  alias Fizz.Runtime.Expression

  @spec evaluate(map(), String.t(), String.t()) :: term()
  def evaluate(context, template, step_id) when is_binary(template) and is_binary(step_id) do
    cond do
      not Expression.contains_expression?(template) ->
        template

      is_nil(Map.get(context, :execution)) ->
        "Run a test to see preview results"

      true ->
        do_evaluate(context, template, step_id)
    end
  end

  def evaluate(_context, template, _step_id), do: template

  defp do_evaluate(context, template, step_id) do
    execution = Map.get(context, :execution)
    step_executions = Map.get(context, :step_executions, [])
    editor_state = Map.get(context, :editor_state, %{})
    draft = context |> Map.get(:workflow, %{}) |> Map.get(:draft)

    step_outputs =
      step_executions
      |> Map.new(fn step_execution ->
        {Map.get(step_execution, :step_id), Map.get(step_execution, :output_data)}
      end)
      |> Map.merge(Map.get(editor_state, :pinned_outputs, %{}))
      |> filter_to_upstream(draft, step_id)

    current_input =
      step_executions
      |> Enum.find(fn step_execution -> Map.get(step_execution, :step_id) == step_id end)
      |> then(fn
        nil -> nil
        step_execution -> Map.get(step_execution, :input_data)
      end)

    vars = Expression.Context.build(execution, step_outputs, current_input)

    case Expression.evaluate_with_vars(template, vars) do
      {:ok, value} -> value_to_display_string(value)
      {:error, reason} -> Map.put(reason, :text, template)
    end
  end

  defp filter_to_upstream(step_outputs, nil, _step_id), do: step_outputs

  defp filter_to_upstream(step_outputs, draft, step_id) when is_map(draft) do
    graph = Fizz.Graph.from_workflow!(draft.steps || [], draft.connections || [], validate: false)
    upstream_ids = Fizz.Graph.upstream(graph, step_id)
    Map.take(step_outputs, upstream_ids)
  rescue
    _ -> step_outputs
  end

  defp filter_to_upstream(step_outputs, _draft, _step_id), do: step_outputs

  defp value_to_display_string(value) when is_binary(value), do: value
  defp value_to_display_string(value) when is_number(value), do: to_string(value)
  defp value_to_display_string(value) when is_atom(value), do: Atom.to_string(value)

  defp value_to_display_string(value) when is_list(value) or is_map(value) do
    inspect(value, limit: :infinity, printable_limit: :infinity)
  end

  defp value_to_display_string(value), do: inspect(value)
end
