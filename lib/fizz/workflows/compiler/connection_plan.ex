defmodule Fizz.Workflows.Compiler.ConnectionPlan do
  @moduledoc false

  alias Fizz.Integrations.Steps.ConnectionHandles

  @spec build(map()) :: {:ok, map()} | {:error, [map()]}
  def build(ir) when is_map(ir) do
    ir.connections
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, initial_plan()}, fn {connection, index}, {:ok, plan} ->
      case plan_connection(ir, connection, index) do
        {:ok, planned_connection} ->
          {:cont, {:ok, add_connection(plan, planned_connection)}}

        {:error, message} ->
          {:halt, {:error, [%{message: message, connection_id: connection.id}]}}
      end
    end)
    |> case do
      {:ok, plan} ->
        case validate_dependency_inputs(ir, plan) do
          {:ok, required_dependencies} ->
            plan = %{plan | required_dependencies: required_dependencies}
            {:ok, Map.put(ir, :connection_plan, plan)}

          {:error, errors} ->
            {:error, errors}
        end

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp initial_plan do
    %{
      connections: %{},
      by_target_step: %{},
      by_source_step: %{},
      required_dependencies: %{}
    }
  end

  defp plan_connection(ir, connection, order) do
    with {:ok, source_step} <- fetch_step(ir, connection.source_step_id, "source"),
         {:ok, target_step} <- fetch_step(ir, connection.target_step_id, "target"),
         {:ok, source_handle} <- source_handle(source_step, connection),
         {:ok, target_handle} <- target_handle(target_step, connection),
         :ok <-
           validate_handle_compatibility(
             connection,
             source_step,
             target_step,
             source_handle,
             target_handle
           ) do
      {:ok,
       %{
         id: connection.id,
         source_step_id: connection.source_step_id,
         source_output: connection.source_output,
         target_step_id: connection.target_step_id,
         target_input: connection.target_input,
         order: order,
         kind: target_handle.kind,
         source_handle: source_handle,
         target_handle: target_handle
       }}
    end
  end

  defp fetch_step(ir, step_id, label) do
    case Map.fetch(ir.steps, step_id) do
      {:ok, step} -> {:ok, step}
      :error -> {:error, "connection references unknown #{label} step `#{step_id}`"}
    end
  end

  defp source_handle(step, connection) do
    with {:ok, handles} <- ConnectionHandles.output_handles(step) do
      case Enum.find(handles, &(&1.id == connection.source_output)) do
        nil ->
          {:error,
           "connection `#{connection.id}` references unknown source output handle `#{connection.source_output}` on step `#{connection.source_step_id}`"}

        handle ->
          {:ok, handle}
      end
    end
  end

  defp target_handle(step, connection) do
    step
    |> ConnectionHandles.input_handles()
    |> Enum.find(&(&1.id == connection.target_input))
    |> case do
      nil ->
        {:error,
         "connection `#{connection.id}` targets unknown input handle `#{connection.target_input}` on step `#{connection.target_step_id}`"}

      handle ->
        {:ok, handle}
    end
  end

  defp validate_handle_compatibility(
         connection,
         _source_step,
         _target_step,
         %{kind: source_kind},
         %{kind: :flow}
       )
       when source_kind != :flow do
    {:error,
     "connection `#{connection.id}` cannot connect non-flow source output `#{connection.source_output}` to flow input `#{connection.target_input}`"}
  end

  defp validate_handle_compatibility(
         connection,
         source_step,
         _target_step,
         source_handle,
         %{kind: :dependency, accepts: %{provides: accepted_provides}}
       ) do
    source_provides = Map.get(source_handle, :provides, [])

    case accepted_provides do
      [] ->
        :ok

      accepted_provides ->
        case Enum.any?(accepted_provides, &(&1 in source_provides)) do
          true ->
            :ok

          false ->
            {:error,
             "dependency input `#{connection.target_input}` on `#{connection.target_step_id}` accepts provides [#{Enum.join(accepted_provides, ", ")}], got `#{source_step.type_id}` with provides [#{Enum.join(source_provides, ", ")}]"}
        end
    end
  end

  defp validate_handle_compatibility(
         _connection,
         _source_step,
         _target_step,
         _source_handle,
         _target_handle
       ),
       do: :ok

  defp add_connection(plan, planned_connection) do
    plan
    |> put_in([:connections, planned_connection.id], planned_connection)
    |> update_by_source_step(planned_connection)
    |> update_by_target_step(planned_connection)
  end

  defp update_by_source_step(plan, planned_connection) do
    update_in(plan, [:by_source_step, planned_connection.source_step_id], fn
      nil -> [planned_connection.id]
      connection_ids -> connection_ids ++ [planned_connection.id]
    end)
  end

  defp update_by_target_step(plan, %{kind: :flow} = planned_connection) do
    target_entry = Map.get(plan.by_target_step, planned_connection.target_step_id, %{})
    connection_ids = Map.get(target_entry, :flow, []) ++ [planned_connection.id]
    target_entry = Map.put(target_entry, :flow, connection_ids)

    %{
      plan
      | by_target_step:
          Map.put(plan.by_target_step, planned_connection.target_step_id, target_entry)
    }
  end

  defp update_by_target_step(plan, %{kind: :dependency} = planned_connection) do
    target_entry = Map.get(plan.by_target_step, planned_connection.target_step_id, %{})
    dependencies = Map.get(target_entry, :dependencies, %{})

    connection_ids =
      Map.get(dependencies, planned_connection.target_input, []) ++ [planned_connection.id]

    dependencies = Map.put(dependencies, planned_connection.target_input, connection_ids)
    target_entry = Map.put(target_entry, :dependencies, dependencies)

    %{
      plan
      | by_target_step:
          Map.put(plan.by_target_step, planned_connection.target_step_id, target_entry)
    }
  end

  defp validate_dependency_inputs(ir, plan) do
    {required_dependencies, errors} =
      Enum.reduce(ir.steps, {%{}, []}, fn {step_id, step}, {required_acc, errors_acc} ->
        {required, errors} = dependency_errors_for_step(step_id, step, plan)

        {
          Map.put(required_acc, step_id, required),
          errors_acc ++ errors
        }
      end)

    case errors do
      [] -> {:ok, required_dependencies}
      _ -> {:error, errors}
    end
  end

  defp dependency_errors_for_step(step_id, step, plan) do
    incoming_dependencies =
      plan
      |> get_in([:by_target_step, step_id, :dependencies])
      |> case do
        nil -> %{}
        dependencies -> dependencies
      end

    handles =
      step
      |> ConnectionHandles.input_handles()
      |> Enum.filter(&(&1.kind == :dependency))

    required =
      handles
      |> Enum.filter(& &1.required?)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    cardinality_errors =
      handles
      |> Enum.flat_map(fn handle ->
        connection_count = incoming_dependencies |> Map.get(handle.id, []) |> length()

        case {handle.cardinality, connection_count} do
          {:one, count} when count > 1 ->
            [
              %{
                step_id: step_id,
                message:
                  "dependency input `#{handle.id}` on `#{step_id}` only accepts one connection"
              }
            ]

          _ ->
            []
        end
      end)

    missing_errors =
      required
      |> Enum.reject(fn handle_id -> Map.get(incoming_dependencies, handle_id, []) != [] end)
      |> Enum.map(fn handle_id ->
        %{
          step_id: step_id,
          message: "step `#{step_id}` is missing required dependency input `#{handle_id}`"
        }
      end)

    {required, cardinality_errors ++ missing_errors}
  end
end
