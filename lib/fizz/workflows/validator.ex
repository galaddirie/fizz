defmodule Fizz.Workflows.Validator do
  @moduledoc """
  Validates workflow draft integrity, including node group boundaries.
  """

  alias Fizz.Steps.Executors.Behaviour, as: StepExecutorBehaviour
  alias Fizz.Steps.Registry, as: StepRegistry
  alias Fizz.Workflows.WorkflowDraft

  @spec validate(WorkflowDraft.t()) :: :ok | {:error, list()}
  def validate(%WorkflowDraft{} = draft) do
    errors =
      []
      |> Kernel.++(validate_group_integrity(draft))
      |> Kernel.++(validate_group_connectivity(draft))
      |> Kernel.++(validate_group_connections(draft))
      |> Kernel.++(validate_no_cross_group_references(draft))
      |> Kernel.++(validate_subnode_connections(draft))
      |> Kernel.++(validate_auth_step_configs(draft))

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

    connections =
      draft.connections
      |> List.wrap()
      |> Enum.filter(&main_connection?/1)

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

    connections =
      draft.connections
      |> List.wrap()
      |> Enum.filter(&main_connection?/1)

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

  defp validate_subnode_connections(draft) do
    steps = draft.steps || []
    connections = draft.connections || []
    steps_by_id = Map.new(steps, &{&1.id, &1})

    connection_errors =
      Enum.flat_map(connections, fn conn ->
        target_input = connection_field(conn, :target_input)

        if main_target_input?(target_input) do
          []
        else
          validate_subnode_connection(conn, steps_by_id)
        end
      end)

    required_and_cardinality_errors =
      Enum.flat_map(steps, fn step ->
        validate_step_slot_requirements(step, connections)
      end)

    connection_errors ++ required_and_cardinality_errors
  end

  defp validate_subnode_connection(conn, steps_by_id) do
    source_step_id = connection_field(conn, :source_step_id)
    target_step_id = connection_field(conn, :target_step_id)
    slot_id = normalize_target_input(connection_field(conn, :target_input))

    with {:ok, source_step} <- fetch_step(steps_by_id, source_step_id),
         {:ok, target_step} <- fetch_step(steps_by_id, target_step_id),
         {:ok, target_type} <- StepRegistry.get(target_step.type_id),
         {:ok, slot_def} <- fetch_slot_def(target_type, slot_id),
         :ok <- validate_slot_accepts_source(slot_def, source_step.type_id) do
      []
    else
      {:error, {:step_not_found, step_id}} ->
        [{:connection, connection_field(conn, :id), "references missing step #{step_id}"}]

      {:error, {:unknown_target_type, type_id}} ->
        [
          {:connection, connection_field(conn, :id),
           "target step type #{type_id} is not registered"}
        ]

      {:error, {:unknown_slot, target_type_id, unknown_slot_id}} ->
        [
          {:connection, connection_field(conn, :id),
           "slot #{unknown_slot_id} is not defined on step type #{target_type_id}"}
        ]

      {:error, {:disallowed_source_type, source_type_id, slot_id_value}} ->
        [
          {:connection, connection_field(conn, :id),
           "step type #{source_type_id} is not allowed for slot #{slot_id_value}"}
        ]
    end
  end

  defp validate_step_slot_requirements(step, connections) do
    case StepRegistry.get(step.type_id) do
      {:ok, target_type} ->
        target_type
        |> slot_defs()
        |> Enum.flat_map(fn slot_def ->
          slot_id = slot_field(slot_def, :id)
          slot_connections = slot_connections_for_step(connections, step.id, slot_id)
          required? = slot_field(slot_def, :required) == true
          cardinality = slot_field(slot_def, :cardinality) || "one"
          slot_errors = []

          slot_errors =
            if required? and slot_connections == [] do
              [{:step, step.id, "required slot #{slot_id} must have at least one connection"}]
            else
              slot_errors
            end

          if cardinality == "one" and length(slot_connections) > 1 do
            [
              {:step, step.id, "slot #{slot_id} allows only one sub-node connection"}
              | slot_errors
            ]
          else
            slot_errors
          end
        end)

      {:error, :not_found} ->
        [{:step, step.id, "step type #{step.type_id} is not registered"}]
    end
  end

  defp fetch_step(steps_by_id, step_id) when is_binary(step_id) do
    case Map.get(steps_by_id, step_id) do
      nil -> {:error, {:step_not_found, step_id}}
      step -> {:ok, step}
    end
  end

  defp fetch_slot_def(target_type, slot_id) when is_binary(slot_id) do
    case Enum.find(slot_defs(target_type), fn slot_def -> slot_field(slot_def, :id) == slot_id end) do
      nil -> {:error, {:unknown_slot, target_type.id, slot_id}}
      slot_def -> {:ok, slot_def}
    end
  end

  defp validate_slot_accepts_source(slot_def, source_type_id) do
    accepted_type_ids = slot_accepts_type_ids(slot_def)

    if source_type_id in accepted_type_ids do
      :ok
    else
      {:error, {:disallowed_source_type, source_type_id, slot_field(slot_def, :id)}}
    end
  end

  defp slot_connections_for_step(connections, step_id, slot_id) do
    Enum.filter(connections, fn conn ->
      connection_field(conn, :target_step_id) == step_id and
        normalize_target_input(connection_field(conn, :target_input)) == slot_id
    end)
  end

  defp slot_defs(type) when is_map(type),
    do: Map.get(type, :subnode_slots) || Map.get(type, "subnode_slots") || []

  defp slot_accepts_type_ids(slot_def) do
    slot_def
    |> slot_field(:accepts)
    |> case do
      accepts when is_map(accepts) ->
        Map.get(accepts, "type_ids") || Map.get(accepts, :type_ids) || []

      _ ->
        []
    end
  end

  defp slot_field(slot_def, field) when is_map(slot_def) and is_atom(field) do
    Map.get(slot_def, field) || Map.get(slot_def, Atom.to_string(field))
  end

  defp connection_field(conn, field) when is_map(conn) and is_atom(field) do
    Map.get(conn, field) || Map.get(conn, Atom.to_string(field))
  end

  defp normalize_target_input(target_input) when target_input in [nil, :main, "main", ""],
    do: "main"

  defp normalize_target_input(target_input) when is_atom(target_input),
    do: Atom.to_string(target_input)

  defp normalize_target_input(target_input) when is_binary(target_input), do: target_input
  defp normalize_target_input(_target_input), do: "main"

  defp main_target_input?(target_input), do: normalize_target_input(target_input) == "main"

  defp main_connection?(connection) do
    connection
    |> connection_field(:target_input)
    |> main_target_input?()
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

  defp validate_auth_step_configs(draft) do
    draft
    |> Map.get(:steps, [])
    |> List.wrap()
    |> Enum.flat_map(fn step ->
      case StepRegistry.get(step.type_id) do
        {:ok, step_type} ->
          if credential_ref_required?(step_type) do
            case StepExecutorBehaviour.validate_config(step.type_id, step.config || %{}) do
              :ok ->
                []

              {:error, errors} ->
                Enum.map(errors, &step_config_error(step.id, &1))
            end
          else
            []
          end

        {:error, :not_found} ->
          []
      end
    end)
  end

  defp credential_ref_required?(step_type) do
    properties =
      step_type
      |> Map.get(:config_schema, %{})
      |> Map.get("properties", %{})

    Map.has_key?(properties, "credential_ref")
  end

  defp step_config_error(step_id, {field, message}) when is_atom(field) and is_binary(message) do
    {:step, step_id, "#{field} #{message}"}
  end

  defp step_config_error(step_id, {field, message})
       when is_binary(field) and is_binary(message) do
    {:step, step_id, "#{field} #{message}"}
  end

  defp step_config_error(step_id, message) when is_binary(message), do: {:step, step_id, message}
  defp step_config_error(step_id, message), do: {:step, step_id, inspect(message)}
end
