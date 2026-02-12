defmodule Fizz.Workflows.Validator do
  @moduledoc """
  Validates workflow draft integrity, including node group boundaries.
  """

  alias Fizz.Workflows.WorkflowDraft

  @spec validate(WorkflowDraft.t()) :: :ok | {:error, list()}
  def validate(%WorkflowDraft{} = draft) do
    errors =
      []
      |> Kernel.++(validate_group_integrity(draft))
      |> Kernel.++(validate_group_connectivity(draft))
      |> Kernel.++(validate_group_connections(draft))
      |> Kernel.++(validate_no_cross_group_references(draft))

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  defp validate_group_integrity(draft) do
    groups = draft.groups || []
    steps = draft.steps || []
    step_ids = MapSet.new(Enum.map(steps, & &1.id))

    grouped_step_ids = Enum.flat_map(groups, & &1.step_ids)

    duplicate_step_ids =
      grouped_step_ids
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)

    missing_step_ids =
      grouped_step_ids
      |> Enum.reject(&MapSet.member?(step_ids, &1))

    errors = []

    errors =
      if duplicate_step_ids == [] do
        errors
      else
        [{:groups, "Steps #{inspect(duplicate_step_ids)} belong to multiple groups"} | errors]
      end

    errors =
      if missing_step_ids == [] do
        errors
      else
        [{:groups, "Groups reference missing steps #{inspect(missing_step_ids)}"} | errors]
      end

    output_errors =
      Enum.flat_map(groups, fn group ->
        if group.output_step_id in (group.step_ids || []) do
          []
        else
          [{:group, group.id, "output_step_id must be one of the group's steps"}]
        end
      end)

    errors ++ output_errors
  end

  defp validate_group_connectivity(draft) do
    groups = draft.groups || []
    connections = draft.connections || []

    Enum.flat_map(groups, fn group ->
      entry_step_id = group_entry_step(group, connections)

      case entry_step_id do
        nil ->
          [{:group, group.id, "must have exactly one entry step"}]

        entry_step_id ->
          reachable = group_reachable_steps(entry_step_id, group, connections)
          missing = MapSet.difference(MapSet.new(group.step_ids), reachable)

          if MapSet.size(missing) == 0 do
            []
          else
            [
              {:group, group.id,
               "contains disconnected steps #{inspect(MapSet.to_list(missing))}"}
            ]
          end
      end
    end)
  end

  defp validate_group_connections(draft) do
    groups = draft.groups || []
    connections = draft.connections || []

    Enum.flat_map(groups, fn group ->
      entry_step_id = group_entry_step(group, connections)

      external_incoming =
        Enum.filter(connections, fn conn ->
          conn.target_step_id in group.step_ids and conn.source_step_id not in group.step_ids
        end)

      incoming_errors =
        if entry_step_id do
          Enum.flat_map(external_incoming, fn conn ->
            if conn.target_step_id == entry_step_id do
              []
            else
              [
                {:group, group.id, "external connections must target entry step #{entry_step_id}"}
              ]
            end
          end)
        else
          []
        end

      outgoing_errors =
        connections
        |> Enum.filter(fn conn ->
          conn.source_step_id in group.step_ids and conn.target_step_id not in group.step_ids
        end)
        |> Enum.flat_map(fn conn ->
          if conn.source_step_id == group.output_step_id do
            []
          else
            [
              {:group, group.id, "only output_step_id can connect outside the group"}
            ]
          end
        end)

      incoming_errors ++ outgoing_errors
    end)
  end

  defp validate_no_cross_group_references(draft) do
    groups = draft.groups || []
    steps = draft.steps || []

    step_to_group =
      groups
      |> Enum.flat_map(fn group -> Enum.map(group.step_ids, &{&1, group.id}) end)
      |> Map.new()

    Enum.flat_map(steps, fn step ->
      step_group = Map.get(step_to_group, step.id)
      referenced_steps = extract_step_references(step.config)

      Enum.flat_map(referenced_steps, fn ref_step_id ->
        ref_group = Map.get(step_to_group, ref_step_id)

        if step_group == ref_group do
          []
        else
          [
            {:step, step.id, "cannot reference #{ref_step_id} across group boundaries"}
          ]
        end
      end)
    end)
  end

  defp group_entry_step(group, connections) do
    internal_incoming =
      connections
      |> Enum.filter(fn conn ->
        conn.target_step_id in group.step_ids and conn.source_step_id in group.step_ids
      end)
      |> Enum.group_by(& &1.target_step_id)

    entry_steps =
      group.step_ids
      |> Enum.filter(fn step_id -> Map.get(internal_incoming, step_id, []) == [] end)

    case entry_steps do
      [entry_step_id] -> entry_step_id
      _ -> nil
    end
  end

  defp group_reachable_steps(entry_step_id, group, connections) do
    adjacency =
      connections
      |> Enum.filter(fn conn ->
        conn.source_step_id in group.step_ids and conn.target_step_id in group.step_ids
      end)
      |> Enum.group_by(& &1.source_step_id, & &1.target_step_id)

    traverse_group([entry_step_id], adjacency, MapSet.new())
  end

  defp traverse_group([], _adjacency, visited), do: visited

  defp traverse_group([current | rest], adjacency, visited) do
    if MapSet.member?(visited, current) do
      traverse_group(rest, adjacency, visited)
    else
      visited = MapSet.put(visited, current)
      children = Map.get(adjacency, current, [])
      traverse_group(children ++ rest, adjacency, visited)
    end
  end

  defp extract_step_references(config) when is_map(config) do
    config
    |> Jason.encode!()
    |> then(fn json ->
      Regex.scan(~r/\{\{\s*steps\.([a-zA-Z0-9_]+)/, json)
      |> Enum.map(fn [_, step_id] -> step_id end)
      |> Enum.uniq()
    end)
  end

  defp extract_step_references(_), do: []
end
