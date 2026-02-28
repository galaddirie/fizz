defmodule Fizz.Collaboration.EditSession.Operations do
  @moduledoc """
  Pure functions for validating and applying edit operations to workflow drafts.
  """

  alias Fizz.Workflows.WorkflowDraft
  alias Fizz.Workflows.Embeds.{Step, Connection, NodeGroup}
  alias Fizz.Graph
  alias Fizz.Steps.Registry, as: StepRegistry
  require Logger

  @doc """
  Normalizes an operation payload by ensuring keys are atoms or strings consistently.
  """
  def normalize_payload(nil), do: %{}

  def normalize_payload(payload) when is_map(payload) do
    # For now we just return as is, but helpers like `field/2` will handle it.
    payload
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_, _), do: nil

  @type operation :: %{
          type: atom(),
          payload: map(),
          id: String.t(),
          user_id: String.t()
        }

  @doc "Validate an operation against current draft state."
  @spec validate(WorkflowDraft.t(), operation()) :: :ok | {:error, term()}
  def validate(draft, operation) do
    case operation.type do
      :add_step ->
        validate_add_step(draft, operation.payload)

      :remove_step ->
        validate_remove_step(draft, operation.payload)

      :update_step_config ->
        validate_update_step(draft, operation.payload)

      :update_step_position ->
        validate_update_step(draft, operation.payload)

      :update_step_positions ->
        validate_update_step_positions(draft, operation.payload)

      :update_step_metadata ->
        validate_update_step(draft, operation.payload)

      :add_connection ->
        validate_add_connection(draft, operation.payload)

      :remove_connection ->
        validate_remove_connection(draft, operation.payload)

      :add_group ->
        validate_add_group(draft, operation.payload)

      :update_group ->
        validate_update_group(draft, operation.payload)

      :remove_group ->
        validate_remove_group(draft, operation.payload)

      :set_group_membership ->
        validate_set_group_membership(draft, operation.payload)

      :commit_drag_layout ->
        validate_commit_drag_layout(draft, operation.payload)

      # Editor operations don't need draft validation
      type when type in [:pin_step_output, :unpin_step_output, :disable_step, :enable_step] ->
        :ok

      _ ->
        {:error, :unknown_operation_type}
    end
  end

  @doc "Apply an operation to a draft, returning updated draft."
  @spec apply(WorkflowDraft.t(), operation() | map()) ::
          {:ok, WorkflowDraft.t()} | {:error, term()}
  def apply(draft, operation) do
    type = field(operation, :type)
    payload = field(operation, :payload)
    Logger.info("Operations.apply: type=#{inspect(type)} payload=#{inspect(payload)}")

    case do_apply(draft, type, payload) do
      {:ok, updated_draft} = result ->
        if draft == updated_draft and
             type not in [:pin_step_output, :unpin_step_output, :disable_step, :enable_step] do
          Logger.warning("Operations.apply: No changes made to draft for type=#{inspect(type)}")
        end

        result

      {:error, reason} = error ->
        Logger.error("Operations.apply FAILED: type=#{inspect(type)} reason=#{inspect(reason)}")
        error
    end
  end

  # ============================================================================
  # Validation Functions
  # ============================================================================

  defp validate_add_step(draft, payload) do
    step_data = field(payload, :step)
    step_id = field(step_data, :id)
    group_id = field(payload, :group_id)

    cond do
      step_exists?(draft, step_id) ->
        {:error, {:step_already_exists, step_id}}

      not valid_step_type?(step_data) ->
        {:error, :invalid_step_type}

      not is_nil(group_id) and not group_exists?(draft, group_id) ->
        {:error, {:group_not_found, group_id}}

      true ->
        :ok
    end
  end

  defp validate_remove_step(draft, payload) do
    step_id = field(payload, :step_id)

    if step_exists?(draft, step_id) do
      :ok
    else
      {:error, {:step_not_found, step_id}}
    end
  end

  defp validate_update_step(draft, payload) do
    step_id = field(payload, :step_id)

    if step_exists?(draft, step_id) do
      :ok
    else
      {:error, {:step_not_found, step_id}}
    end
  end

  defp validate_update_step_positions(draft, payload) do
    step_positions = field(payload, :step_positions)

    if is_map(step_positions) do
      step_ids = Map.keys(step_positions)
      missing = Enum.reject(step_ids, &step_exists?(draft, &1))

      if missing == [] do
        :ok
      else
        {:error, {:steps_not_found, missing}}
      end
    else
      {:error, :invalid_step_positions}
    end
  end

  defp validate_add_connection(draft, payload) do
    conn_data = field(payload, :connection)
    source_id = field(conn_data, :source_step_id)
    target_id = field(conn_data, :target_step_id)
    conn_id = field(conn_data, :id)

    cond do
      connection_exists?(draft, conn_id) ->
        {:error, {:connection_already_exists, conn_id}}

      not step_exists?(draft, source_id) ->
        {:error, {:source_step_not_found, source_id}}

      not step_exists?(draft, target_id) ->
        {:error, {:target_step_not_found, target_id}}

      source_id == target_id ->
        {:error, :self_loop_not_allowed}

      would_create_cycle?(draft, source_id, target_id) ->
        {:error, :would_create_cycle}

      true ->
        validate_subnode_slot_connection(draft, conn_data)
    end
  end

  defp validate_remove_connection(draft, payload) do
    conn_id = field(payload, :connection_id)

    if connection_exists?(draft, conn_id) do
      :ok
    else
      {:error, {:connection_not_found, conn_id}}
    end
  end

  defp validate_add_group(draft, payload) do
    group_data = field(payload, :group) || %{}
    group_id = field(group_data, :id)
    step_ids = List.wrap(field(group_data, :step_ids) || [])
    missing_steps = Enum.reject(step_ids, &step_exists?(draft, &1))

    cond do
      is_nil(group_id) ->
        {:error, :group_id_required}

      group_exists?(draft, group_id) ->
        {:error, {:group_already_exists, group_id}}

      step_ids == [] ->
        {:error, :group_requires_steps}

      missing_steps != [] ->
        {:error, {:group_steps_not_found, missing_steps}}

      true ->
        :ok
    end
  end

  defp validate_update_group(draft, payload) do
    group_id = field(payload, :group_id)
    changes = field(payload, :changes) || %{}

    if group_exists?(draft, group_id) do
      case Map.get(changes, "output_step_id") || Map.get(changes, :output_step_id) do
        nil ->
          :ok

        output_step_id ->
          case find_group(draft, group_id) do
            nil ->
              {:error, {:group_not_found, group_id}}

            group ->
              if output_step_id in (field(group, :step_ids) || []) do
                :ok
              else
                {:error, {:invalid_group_output, output_step_id}}
              end
          end
      end
    else
      {:error, {:group_not_found, group_id}}
    end
  end

  defp validate_remove_group(draft, payload) do
    group_id = field(payload, :group_id)

    if group_exists?(draft, group_id) do
      :ok
    else
      {:error, {:group_not_found, group_id}}
    end
  end

  defp validate_set_group_membership(draft, payload) do
    group_id = field(payload, :group_id)
    step_ids = List.wrap(field(payload, :step_ids) || [])

    cond do
      step_ids == [] ->
        {:error, :group_membership_missing_steps}

      Enum.any?(step_ids, fn step_id -> not step_exists?(draft, step_id) end) ->
        missing = Enum.reject(step_ids, &step_exists?(draft, &1))
        {:error, {:group_steps_not_found, missing}}

      is_nil(group_id) ->
        :ok

      group_exists?(draft, group_id) ->
        :ok

      true ->
        {:error, {:group_not_found, group_id}}
    end
  end

  defp validate_commit_drag_layout(draft, payload) do
    groups = List.wrap(field(payload, :groups) || [])
    step_positions = field(payload, :step_positions) || %{}
    group_id_by_step_id = field(payload, :group_id_by_step_id) || %{}

    cond do
      not is_map(step_positions) ->
        {:error, :invalid_step_positions}

      not is_map(group_id_by_step_id) ->
        {:error, :invalid_group_membership_map}

      true ->
        validate_commit_drag_layout_references(draft, groups, step_positions, group_id_by_step_id)
    end
  end

  defp validate_commit_drag_layout_references(draft, groups, step_positions, group_id_by_step_id) do
    group_ids =
      groups
      |> Enum.map(&field(&1, :group_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    missing_groups =
      group_ids
      |> Enum.reject(&group_exists?(draft, &1))
      |> Kernel.++(missing_group_membership_targets(draft, group_id_by_step_id))
      |> Enum.uniq()

    step_ids =
      step_positions
      |> Map.keys()
      |> Kernel.++(Map.keys(group_id_by_step_id))
      |> Enum.uniq()

    missing_steps = Enum.reject(step_ids, &step_exists?(draft, &1))

    cond do
      missing_groups != [] ->
        {:error, {:groups_not_found, missing_groups}}

      missing_steps != [] ->
        {:error, {:steps_not_found, missing_steps}}

      true ->
        :ok
    end
  end

  defp missing_group_membership_targets(draft, group_id_by_step_id) do
    group_id_by_step_id
    |> Enum.reduce([], fn {_step_id, group_id}, acc ->
      normalized_group_id =
        case group_id do
          "" -> nil
          value -> value
        end

      if is_nil(normalized_group_id) or group_exists?(draft, normalized_group_id) do
        acc
      else
        [normalized_group_id | acc]
      end
    end)
  end

  # ============================================================================
  # Apply Functions
  # ============================================================================

  defp do_apply(draft, :add_step, payload) do
    step_data = field(payload, :step)
    step = build_step(step_data)
    new_steps = (draft.steps || []) ++ [step]
    group_id = field(payload, :group_id)

    draft = %{draft | steps: new_steps}

    draft =
      if is_nil(group_id) do
        draft
      else
        update_groups(draft, fn groups ->
          add_steps_to_group(groups, group_id, [step.id])
        end)
      end

    {:ok, draft}
  end

  defp do_apply(draft, :remove_step, payload) do
    step_id = field(payload, :step_id)
    Logger.info("Operations.do_apply(:remove_step): step_id=#{inspect(step_id)}")

    # Remove step and all its connections
    new_steps =
      Enum.reject(draft.steps || [], fn step ->
        id = field(step, :id)
        match = id == step_id
        if match, do: Logger.info("Operations.do_apply: Found step to remove: #{id}")
        match
      end)

    new_connections =
      Enum.reject(draft.connections || [], fn conn ->
        source_id = field(conn, :source_step_id)
        target_id = field(conn, :target_step_id)
        match = source_id == step_id or target_id == step_id

        if match,
          do:
            Logger.info(
              "Operations.do_apply: Removing connection #{field(conn, :id)} because it links to removed step #{step_id}"
            )

        match
      end)

    new_groups =
      draft.groups
      |> List.wrap()
      |> remove_steps_from_groups([step_id])

    {:ok, %{draft | steps: new_steps, connections: new_connections, groups: new_groups}}
  end

  defp do_apply(draft, :update_step_config, payload) do
    step_id = field(payload, :step_id)
    patch = field(payload, :patch)

    update_step(draft, step_id, fn step ->
      new_config = apply_json_patch(step.config || %{}, patch)
      %{step | config: new_config}
    end)
  end

  defp do_apply(draft, :update_step_position, payload) do
    step_id = field(payload, :step_id)
    position = field(payload, :position)

    update_step(draft, step_id, fn step ->
      %{step | position: position}
    end)
  end

  defp do_apply(draft, :update_step_positions, payload) do
    step_positions = field(payload, :step_positions) || %{}
    {:ok, update_step_positions(draft, step_positions)}
  end

  defp do_apply(draft, :update_step_metadata, payload) do
    step_id = field(payload, :step_id)
    changes = field(payload, :changes)

    # Handle name uniqueness if it's changing
    changes =
      case Map.get(changes, "name") || Map.get(changes, :name) do
        nil ->
          changes

        new_name ->
          other_steps = Enum.reject(draft.steps || [], &(&1.id == step_id))

          {unique_name, _unique_step_id} =
            Fizz.Workflows.generate_unique_step_identity(other_steps, new_name)

          Map.put(changes, :name, unique_name)
      end

    update_step(draft, step_id, fn step ->
      step
      |> maybe_update(:name, changes)
      |> maybe_update(:notes, changes)
      |> maybe_update(:config, changes)
    end)
  end

  defp do_apply(draft, :add_connection, payload) do
    conn_data = field(payload, :connection)
    connection = build_connection(conn_data)
    new_connections = (draft.connections || []) ++ [connection]
    {:ok, %{draft | connections: new_connections}}
  end

  defp do_apply(draft, :remove_connection, payload) do
    conn_id = field(payload, :connection_id)
    new_connections = Enum.reject(draft.connections || [], &(field(&1, :id) == conn_id))
    {:ok, %{draft | connections: new_connections}}
  end

  defp do_apply(draft, :add_group, payload) do
    group_data = field(payload, :group) || %{}
    step_positions = field(payload, :step_positions) || %{}
    step_ids = List.wrap(field(group_data, :step_ids) || [])
    group = build_group(group_data, draft)

    groups =
      draft.groups
      |> List.wrap()
      |> remove_steps_from_groups(step_ids)
      |> Kernel.++([group])
      |> normalize_groups()

    draft = %{draft | groups: groups}
    draft = update_step_positions(draft, step_positions)
    {:ok, draft}
  end

  defp do_apply(draft, :update_group, payload) do
    group_id = field(payload, :group_id)
    changes = field(payload, :changes) || %{}

    update_group(draft, group_id, fn group ->
      group
      |> maybe_update(:name, changes)
      |> maybe_update(:position, changes)
      |> maybe_update(:color, changes)
      |> maybe_update(:collapsed, changes)
      |> maybe_update(:output_step_id, changes)
    end)
  end

  defp do_apply(draft, :remove_group, payload) do
    group_id = field(payload, :group_id)

    case find_group(draft, group_id) do
      nil ->
        {:error, {:group_not_found, group_id}}

      group ->
        group_position = field(group, :position) || %{}
        offset_x = field(group_position, :x) || 0
        offset_y = field(group_position, :y) || 0

        step_positions =
          group
          |> field(:step_ids)
          |> List.wrap()
          |> Enum.reduce(%{}, fn step_id, acc ->
            case find_step(draft, step_id) do
              nil ->
                acc

              step ->
                position = field(step, :position) || %{}

                new_position = %{
                  x: (field(position, :x) || 0) + offset_x,
                  y: (field(position, :y) || 0) + offset_y
                }

                Map.put(acc, step_id, new_position)
            end
          end)

        groups =
          draft.groups
          |> List.wrap()
          |> Enum.reject(fn group_item -> field(group_item, :id) == group_id end)
          |> normalize_groups()

        draft = %{draft | groups: groups}
        draft = update_step_positions(draft, step_positions)
        {:ok, draft}
    end
  end

  defp do_apply(draft, :set_group_membership, payload) do
    group_id = field(payload, :group_id)
    step_ids = List.wrap(field(payload, :step_ids) || [])
    step_positions = field(payload, :step_positions) || %{}

    groups =
      draft.groups
      |> List.wrap()
      |> remove_steps_from_groups(step_ids)
      |> maybe_add_steps_to_group(group_id, step_ids)
      |> normalize_groups()

    draft = %{draft | groups: groups}
    draft = update_step_positions(draft, step_positions)
    {:ok, draft}
  end

  defp do_apply(draft, :commit_drag_layout, payload) do
    groups = List.wrap(field(payload, :groups) || [])
    step_positions = field(payload, :step_positions) || %{}
    group_id_by_step_id = field(payload, :group_id_by_step_id) || %{}
    membership_step_ids = Map.keys(group_id_by_step_id)

    groups_after_membership =
      draft.groups
      |> List.wrap()
      |> remove_steps_from_groups(membership_step_ids)
      |> apply_group_membership_map(group_id_by_step_id)
      |> normalize_groups()

    groups_with_positions = apply_group_positions(groups_after_membership, groups)
    draft = %{draft | groups: groups_with_positions}
    draft = update_step_positions(draft, step_positions)
    {:ok, draft}
  end

  defp do_apply(draft, type, _payload)
       when type in [:pin_step_output, :unpin_step_output, :disable_step, :enable_step] do
    {:ok, draft}
  end

  defp do_apply(_draft, type, _payload) do
    {:error, {:unhandled_operation, type}}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp step_exists?(draft, step_id) do
    Enum.any?(draft.steps || [], fn step -> field(step, :id) == step_id end)
  end

  defp connection_exists?(draft, conn_id) do
    Enum.any?(draft.connections || [], fn conn -> field(conn, :id) == conn_id end)
  end

  defp group_exists?(draft, group_id) do
    Enum.any?(draft.groups || [], fn group -> field(group, :id) == group_id end)
  end

  defp find_group(draft, group_id) do
    Enum.find(draft.groups || [], fn group -> field(group, :id) == group_id end)
  end

  defp find_step(draft, step_id) do
    Enum.find(draft.steps || [], fn step -> field(step, :id) == step_id end)
  end

  defp update_group(draft, group_id, update_fn) do
    groups = draft.groups || []

    {updated_groups, updated?} =
      Enum.reduce(groups, {[], false}, fn group, {acc, updated?} ->
        if field(group, :id) == group_id do
          updated =
            case update_fn.(group) do
              {:ok, updated_group} -> updated_group
              %NodeGroup{} = updated_group -> updated_group
              updated_group when is_map(updated_group) -> updated_group
            end

          {[updated | acc], true}
        else
          {[group | acc], updated?}
        end
      end)

    if updated? do
      {:ok, %{draft | groups: Enum.reverse(updated_groups)}}
    else
      {:error, {:group_not_found, group_id}}
    end
  end

  defp update_groups(draft, update_fn) do
    groups = update_fn.(List.wrap(draft.groups))
    %{draft | groups: normalize_groups(groups)}
  end

  defp remove_steps_from_groups(groups, step_ids) do
    step_id_set = MapSet.new(step_ids)

    groups
    |> Enum.map(fn group ->
      updated_step_ids =
        group
        |> field(:step_ids)
        |> List.wrap()
        |> Enum.reject(&MapSet.member?(step_id_set, &1))

      update_group_fields(group, %{step_ids: updated_step_ids})
    end)
    |> normalize_groups()
  end

  defp add_steps_to_group(groups, group_id, step_ids) do
    Enum.map(groups, fn group ->
      if field(group, :id) == group_id do
        updated_step_ids =
          group
          |> field(:step_ids)
          |> List.wrap()
          |> Kernel.++(step_ids)
          |> Enum.uniq()

        update_group_fields(group, %{step_ids: updated_step_ids})
      else
        group
      end
    end)
  end

  defp maybe_add_steps_to_group(groups, nil, _step_ids), do: groups

  defp maybe_add_steps_to_group(groups, group_id, step_ids),
    do: add_steps_to_group(groups, group_id, step_ids)

  defp apply_group_membership_map(groups, group_id_by_step_id) do
    Enum.reduce(group_id_by_step_id, groups, fn {step_id, group_id}, acc ->
      normalized_group_id =
        case group_id do
          "" -> nil
          value -> value
        end

      case normalized_group_id do
        nil -> acc
        value -> add_steps_to_group(acc, value, [step_id])
      end
    end)
  end

  defp apply_group_positions(groups, group_changes) do
    Enum.reduce(group_changes, groups, fn change, acc ->
      group_id = field(change, :group_id)
      position = field(change, :position) || %{}

      Enum.map(acc, fn group ->
        if field(group, :id) == group_id do
          update_group_fields(group, %{position: position})
        else
          group
        end
      end)
    end)
  end

  defp normalize_groups(groups) do
    groups
    |> Enum.reduce([], fn group, acc ->
      step_ids = group |> field(:step_ids) |> List.wrap() |> Enum.uniq()

      cond do
        step_ids == [] ->
          acc

        field(group, :output_step_id) in step_ids ->
          [update_group_fields(group, %{step_ids: step_ids}) | acc]

        true ->
          [update_group_fields(group, %{step_ids: step_ids, output_step_id: hd(step_ids)}) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp update_step_positions(draft, step_positions) do
    if step_positions == %{} do
      draft
    else
      new_steps =
        Enum.map(draft.steps || [], fn step ->
          case field(step_positions, step.id) do
            %{} = position ->
              %{step | position: position}

            _ ->
              step
          end
        end)

      %{draft | steps: new_steps}
    end
  end

  defp build_group(data, draft) when is_map(data) do
    step_ids =
      data
      |> field(:step_ids)
      |> List.wrap()
      |> Enum.uniq()

    output_step_id = resolve_group_output_step_id(data, step_ids, draft.connections || [])

    %NodeGroup{
      id: field(data, :id),
      name: field(data, :name) || "Group",
      step_ids: step_ids,
      output_step_id: output_step_id,
      position: field(data, :position) || %{},
      color: field(data, :color),
      collapsed: field(data, :collapsed) || false
    }
  end

  defp resolve_group_output_step_id(data, step_ids, connections) do
    output_step_id = field(data, :output_step_id)

    cond do
      output_step_id in step_ids ->
        output_step_id

      step_ids == [] ->
        output_step_id

      true ->
        infer_group_output_step_id(step_ids, connections)
    end
  end

  defp infer_group_output_step_id(step_ids, connections) do
    step_set = MapSet.new(step_ids)

    outgoing_to_outside =
      connections
      |> Enum.filter(fn conn ->
        source_id = field(conn, :source_step_id)
        target_id = field(conn, :target_step_id)
        MapSet.member?(step_set, source_id) and not MapSet.member?(step_set, target_id)
      end)
      |> Enum.map(&field(&1, :source_step_id))
      |> Enum.uniq()

    cond do
      length(outgoing_to_outside) == 1 ->
        hd(outgoing_to_outside)

      true ->
        internal_sources =
          connections
          |> Enum.filter(fn conn ->
            source_id = field(conn, :source_step_id)
            target_id = field(conn, :target_step_id)
            MapSet.member?(step_set, source_id) and MapSet.member?(step_set, target_id)
          end)
          |> Enum.map(&field(&1, :source_step_id))
          |> MapSet.new()

        leaf_ids = Enum.reject(step_ids, &MapSet.member?(internal_sources, &1))

        if length(leaf_ids) == 1 do
          hd(leaf_ids)
        else
          hd(step_ids)
        end
    end
  end

  defp update_group_fields(group, attrs) when is_map(group) do
    if Map.has_key?(group, :__struct__) do
      struct(group, attrs)
    else
      Map.merge(group, attrs)
    end
  end

  defp valid_step_type?(step_data) do
    type_id = field(step_data, :type_id)
    StepRegistry.exists?(type_id)
  end

  defp validate_subnode_slot_connection(draft, conn_data) do
    target_input = normalize_target_input(field(conn_data, :target_input))

    if target_input == "main" do
      :ok
    else
      with {:ok, target_step} <- fetch_step(draft, field(conn_data, :target_step_id)),
           {:ok, source_step} <- fetch_step(draft, field(conn_data, :source_step_id)),
           {:ok, target_type} <- StepRegistry.get(target_step.type_id),
           {:ok, slot_def} <- fetch_slot_definition(target_type, target_input),
           :ok <- validate_slot_accepts_type(slot_def, source_step.type_id),
           :ok <- validate_slot_cardinality(draft, conn_data, slot_def) do
        :ok
      else
        {:error, :step_not_found} ->
          {:error, :step_not_found}

        {:error, :not_found} ->
          {:error, :target_step_type_not_found}

        {:error, {:slot_not_found, slot_id}} ->
          {:error, {:invalid_target_input, slot_id}}

        {:error, {:slot_disallows_type, slot_id, source_type_id}} ->
          {:error, {:slot_disallows_source_type, slot_id, source_type_id}}

        {:error, {:slot_cardinality_exceeded, slot_id}} ->
          {:error, {:slot_cardinality_exceeded, slot_id}}
      end
    end
  end

  defp validate_slot_cardinality(draft, conn_data, slot_def) do
    case slot_field(slot_def, :cardinality) do
      "many" ->
        :ok

      _ ->
        target_step_id = field(conn_data, :target_step_id)
        slot_id = normalize_target_input(field(conn_data, :target_input))

        existing_count =
          draft.connections
          |> List.wrap()
          |> Enum.count(fn conn ->
            field(conn, :target_step_id) == target_step_id and
              normalize_target_input(field(conn, :target_input)) == slot_id
          end)

        if existing_count >= 1 do
          {:error, {:slot_cardinality_exceeded, slot_id}}
        else
          :ok
        end
    end
  end

  defp fetch_step(draft, step_id) do
    case find_step(draft, step_id) do
      nil -> {:error, :step_not_found}
      step -> {:ok, step}
    end
  end

  defp fetch_slot_definition(target_type, slot_id) do
    slots = Map.get(target_type, :subnode_slots, [])

    case Enum.find(slots, fn slot -> slot_field(slot, :id) == slot_id end) do
      nil -> {:error, {:slot_not_found, slot_id}}
      slot -> {:ok, slot}
    end
  end

  defp validate_slot_accepts_type(slot_def, source_type_id) do
    accepted_type_ids =
      slot_def
      |> slot_field(:accepts)
      |> case do
        accepts when is_map(accepts) ->
          Map.get(accepts, "type_ids") || Map.get(accepts, :type_ids) || []

        _ ->
          []
      end

    if source_type_id in accepted_type_ids do
      :ok
    else
      {:error, {:slot_disallows_type, slot_field(slot_def, :id), source_type_id}}
    end
  end

  defp slot_field(slot, key) when is_map(slot) and is_atom(key) do
    Map.get(slot, key) || Map.get(slot, Atom.to_string(key))
  end

  defp normalize_target_input(target_input) when target_input in [nil, "", :main, "main"],
    do: "main"

  defp normalize_target_input(target_input) when is_binary(target_input), do: target_input

  defp normalize_target_input(target_input) when is_atom(target_input),
    do: Atom.to_string(target_input)

  defp normalize_target_input(_target_input), do: "main"

  defp would_create_cycle?(draft, source_id, target_id) do
    # Build graph with proposed edge and check for cycles
    case Graph.from_workflow(draft.steps, draft.connections) do
      {:ok, graph} ->
        # Add the proposed edge
        test_graph = Graph.add_edge(graph, source_id, target_id)
        # Check if target can reach source (would indicate cycle)
        target_id in Graph.upstream(test_graph, source_id)

      {:error, _} ->
        false
    end
  end

  defp update_step(draft, step_id, update_fn) do
    new_steps =
      Enum.map(draft.steps || [], fn step ->
        if field(step, :id) == step_id do
          case update_fn.(step) do
            {:ok, updated} -> updated
            %Step{} = updated -> updated
            updated when is_map(updated) -> updated
          end
        else
          step
        end
      end)

    {:ok, %{draft | steps: new_steps}}
  end

  defp build_step(data) when is_map(data) do
    %Step{
      id: field(data, :id),
      type_id: field(data, :type_id),
      name: field(data, :name),
      config: field(data, :config) || %{},
      position: field(data, :position) || %{x: 0, y: 0},
      notes: field(data, :notes)
    }
  end

  defp build_connection(data) when is_map(data) do
    %Connection{
      id: field(data, :id),
      source_step_id: field(data, :source_step_id),
      source_output: field(data, :source_output) || "main",
      target_step_id: field(data, :target_step_id),
      target_input: field(data, :target_input) || "main"
    }
  end

  @doc false
  def apply_json_patch(config, patches) when is_list(patches) do
    Enum.reduce(patches, config, &apply_single_patch/2)
  end

  defp apply_single_patch(%{"op" => "replace", "path" => path, "value" => value}, config) do
    put_at_path(config, parse_path(path), value)
  end

  defp apply_single_patch(%{"op" => "add", "path" => path, "value" => value}, config) do
    put_at_path(config, parse_path(path), value)
  end

  defp apply_single_patch(%{"op" => "remove", "path" => path}, config) do
    remove_at_path(config, parse_path(path))
  end

  defp apply_single_patch(_, config), do: config

  defp parse_path("/" <> path), do: String.split(path, "/", trim: true)
  defp parse_path(path), do: String.split(path, "/", trim: true)

  defp put_at_path(map, [key], value) do
    Map.put(map, key, value)
  end

  defp put_at_path(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, put_at_path(nested, rest, value))
  end

  defp remove_at_path(map, [key]) do
    Map.delete(map, key)
  end

  defp remove_at_path(map, [key | rest]) do
    case Map.get(map, key) do
      nested when is_map(nested) ->
        Map.put(map, key, remove_at_path(nested, rest))

      _ ->
        map
    end
  end

  defp maybe_update(struct, field, changes) do
    case Map.get(changes, field) || Map.get(changes, to_string(field)) do
      nil -> struct
      value -> Map.put(struct, field, value)
    end
  end
end
