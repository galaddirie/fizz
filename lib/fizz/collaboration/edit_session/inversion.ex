defmodule Fizz.Collaboration.EditSession.Inversion do
  @moduledoc """
  Computes inverse operations for undo/redo support.
  """

  alias Fizz.Collaboration.EditorState
  alias Fizz.Workflows.WorkflowDraft

  @spec compute_inverse(WorkflowDraft.t(), EditorState.t(), map()) ::
          {:ok, [map()]} | {:error, term()}
  def compute_inverse(%WorkflowDraft{} = draft, %EditorState{} = editor_state, operation) do
    type = field(operation, :type)
    payload = field(operation, :payload) || %{}

    case type do
      :add_step ->
        step_id = field(field(payload, :step) || %{}, :id)
        {:ok, [%{type: :remove_step, payload: %{step_id: step_id}}]}

      :remove_step ->
        step_id = field(payload, :step_id)

        case find_step(draft, step_id) do
          nil ->
            {:error, :step_not_found}

          step ->
            connections = find_step_connections(draft, step_id)
            group_id = find_group_for_step(draft, step_id)

            step_payload =
              if is_nil(group_id) do
                %{step: to_map(step)}
              else
                %{step: to_map(step), group_id: group_id}
              end

            connection_ops =
              Enum.map(connections, fn conn ->
                %{type: :add_connection, payload: %{connection: to_map(conn)}}
              end)

            {:ok, [%{type: :add_step, payload: step_payload} | connection_ops]}
        end

      :update_step_config ->
        step_id = field(payload, :step_id)
        patch = field(payload, :patch) || []

        case find_step(draft, step_id) do
          nil ->
            {:error, :step_not_found}

          step ->
            inverse_patch = compute_reverse_patch(field(step, :config) || %{}, patch)

            {:ok,
             [
               %{
                 type: :update_step_config,
                 payload: %{step_id: step_id, patch: inverse_patch}
               }
             ]}
        end

      :update_step_position ->
        step_id = field(payload, :step_id)

        case find_step(draft, step_id) do
          nil ->
            {:error, :step_not_found}

          step ->
            {:ok,
             [
               %{
                 type: :update_step_position,
                 payload: %{step_id: step_id, position: field(step, :position)}
               }
             ]}
        end

      :update_step_positions ->
        step_positions = field(payload, :step_positions) || %{}
        step_ids = Map.keys(step_positions)
        missing_ids = Enum.filter(step_ids, &is_nil(find_step(draft, &1)))

        if missing_ids == [] do
          {:ok,
           [
             %{
               type: :update_step_positions,
               payload: %{step_positions: capture_step_positions(draft, step_ids)}
             }
           ]}
        else
          {:error, {:steps_not_found, missing_ids}}
        end

      :update_step_metadata ->
        step_id = field(payload, :step_id)
        changes = field(payload, :changes) || %{}

        case find_step(draft, step_id) do
          nil ->
            {:error, :step_not_found}

          step ->
            previous =
              changes
              |> Map.keys()
              |> Enum.reduce(%{}, fn key, acc ->
                Map.put(acc, key, field(step, key))
              end)

            {:ok,
             [
               %{
                 type: :update_step_metadata,
                 payload: %{step_id: step_id, changes: previous}
               }
             ]}
        end

      :add_connection ->
        conn_id = field(field(payload, :connection) || %{}, :id)
        {:ok, [%{type: :remove_connection, payload: %{connection_id: conn_id}}]}

      :remove_connection ->
        conn_id = field(payload, :connection_id)

        case find_connection(draft, conn_id) do
          nil -> {:error, :connection_not_found}
          conn -> {:ok, [%{type: :add_connection, payload: %{connection: to_map(conn)}}]}
        end

      :add_group ->
        group_id = field(field(payload, :group) || %{}, :id)
        {:ok, [%{type: :remove_group, payload: %{group_id: group_id}}]}

      :update_group ->
        group_id = field(payload, :group_id)
        changes = field(payload, :changes) || %{}

        case find_group(draft, group_id) do
          nil ->
            {:error, :group_not_found}

          group ->
            previous =
              changes
              |> Map.keys()
              |> Enum.reduce(%{}, fn key, acc ->
                Map.put(acc, key, field(group, key))
              end)

            {:ok,
             [
               %{
                 type: :update_group,
                 payload: %{group_id: group_id, changes: previous}
               }
             ]}
        end

      :remove_group ->
        group_id = field(payload, :group_id)

        case find_group(draft, group_id) do
          nil ->
            {:error, :group_not_found}

          group ->
            step_ids = List.wrap(field(group, :step_ids) || [])
            step_positions = capture_step_positions(draft, step_ids)

            {:ok,
             [
               %{
                 type: :add_group,
                 payload: %{group: to_map(group), step_positions: step_positions}
               }
             ]}
        end

      :set_group_membership ->
        step_ids = List.wrap(field(payload, :step_ids) || [])

        inverse_ops =
          step_ids
          |> Enum.group_by(&find_group_for_step(draft, &1))
          |> Enum.map(fn {group_id, ids} ->
            %{
              type: :set_group_membership,
              payload: %{
                group_id: group_id,
                step_ids: ids,
                step_positions: capture_step_positions(draft, ids)
              }
            }
          end)

        {:ok, inverse_ops}

      :pin_step_output ->
        step_id = field(payload, :step_id)
        {:ok, [%{type: :unpin_step_output, payload: %{step_id: step_id}}]}

      :unpin_step_output ->
        step_id = field(payload, :step_id)
        pinned_data = Map.get(editor_state.pinned_outputs, step_id)

        {:ok,
         [
           %{
             type: :pin_step_output,
             payload: %{step_id: step_id, output_data: pinned_data}
           }
         ]}

      :disable_step ->
        step_id = field(payload, :step_id)
        {:ok, [%{type: :enable_step, payload: %{step_id: step_id}}]}

      :enable_step ->
        step_id = field(payload, :step_id)
        mode = Map.get(editor_state.disabled_mode, step_id, :skip)

        {:ok,
         [
           %{
             type: :disable_step,
             payload: %{step_id: step_id, mode: mode}
           }
         ]}

      _ ->
        {:error, :unknown_operation_type}
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_, _), do: nil

  defp to_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp to_map(map) when is_map(map), do: map

  defp find_step(%WorkflowDraft{} = draft, step_id) do
    Enum.find(draft.steps || [], fn step -> field(step, :id) == step_id end)
  end

  defp find_connection(%WorkflowDraft{} = draft, conn_id) do
    Enum.find(draft.connections || [], fn conn -> field(conn, :id) == conn_id end)
  end

  defp find_group(%WorkflowDraft{} = draft, group_id) do
    Enum.find(List.wrap(draft.groups), fn group -> field(group, :id) == group_id end)
  end

  defp find_group_for_step(%WorkflowDraft{} = draft, step_id) do
    draft.groups
    |> List.wrap()
    |> Enum.find_value(fn group ->
      step_ids = List.wrap(field(group, :step_ids) || [])
      if step_id in step_ids, do: field(group, :id), else: nil
    end)
  end

  defp find_step_connections(%WorkflowDraft{} = draft, step_id) do
    Enum.filter(draft.connections || [], fn conn ->
      field(conn, :source_step_id) == step_id or field(conn, :target_step_id) == step_id
    end)
  end

  defp capture_step_positions(%WorkflowDraft{} = draft, step_ids) do
    step_set = MapSet.new(step_ids)

    draft.steps
    |> List.wrap()
    |> Enum.reduce(%{}, fn step, acc ->
      step_id = field(step, :id)

      if MapSet.member?(step_set, step_id) do
        Map.put(acc, step_id, field(step, :position) || %{})
      else
        acc
      end
    end)
  end

  defp compute_reverse_patch(config, patches) do
    patches
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.map(&reverse_patch(config, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp reverse_patch(config, patch) when is_map(patch) do
    op = Map.get(patch, "op") || Map.get(patch, :op)
    path = Map.get(patch, "path") || Map.get(patch, :path)

    case op do
      "replace" ->
        case get_at_path(config, parse_path(path)) do
          :missing -> %{"op" => "remove", "path" => path}
          value -> %{"op" => "replace", "path" => path, "value" => value}
        end

      "add" ->
        case get_at_path(config, parse_path(path)) do
          :missing -> %{"op" => "remove", "path" => path}
          value -> %{"op" => "replace", "path" => path, "value" => value}
        end

      "remove" ->
        case get_at_path(config, parse_path(path)) do
          :missing -> nil
          value -> %{"op" => "add", "path" => path, "value" => value}
        end

      _ ->
        nil
    end
  end

  defp parse_path(nil), do: []
  defp parse_path("/" <> path), do: String.split(path, "/", trim: true)
  defp parse_path(path), do: String.split(path, "/", trim: true)

  defp get_at_path(map, []), do: map

  defp get_at_path(map, [key | rest]) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, to_string(key))

    case value do
      nil -> :missing
      _ -> get_at_path(value, rest)
    end
  end

  defp get_at_path(_, _), do: :missing
end
