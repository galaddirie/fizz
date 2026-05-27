defmodule Fizz.Workflows.DraftSession.Operation do
  @moduledoc false

  alias Ecto.Changeset
  alias Fizz.Integrations.StepRegistry, as: StepRegistry
  alias Fizz.Workflows.Embeds.{Connection, Step, StepGroup}
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @type operation() :: %{
          required(:type) => atom(),
          required(:params) => map(),
          optional(:label) => String.t()
        }

  @string_operation_types %{
    "add_step" => :add_step,
    "remove_step" => :remove_step,
    "update_step" => :update_step,
    "move_step" => :move_step,
    "move_steps" => :move_steps,
    "add_connection" => :add_connection,
    "remove_connection" => :remove_connection,
    "add_group" => :add_group,
    "update_group" => :update_group,
    "remove_group" => :remove_group,
    "set_group_membership" => :set_group_membership,
    "commit_drag_layout" => :commit_drag_layout,
    "duplicate_steps" => :duplicate_steps,
    "tidy_layout" => :tidy_layout,
    "remove_steps" => :remove_steps,
    "restore_steps" => :restore_steps,
    "restore_snapshot" => :restore_snapshot
  }

  @step_update_fields [:type_id, :name, :config, :position, :notes]
  @group_update_fields [:name, :position, :color, :font_size, :collapsed]
  @default_handle "main"

  @spec apply(WorkflowDefinitionVersion.t(), map()) ::
          {:ok, WorkflowDefinitionVersion.t(), operation()} | {:error, term()}
  def apply(%WorkflowDefinitionVersion{} = draft, operation) when is_map(operation) do
    with {:ok, type} <- normalize_type(operation),
         {:ok, params} <- fetch_params(operation) do
      apply_operation(draft, type, params)
    end
  end

  def apply(_draft, _operation), do: {:error, :invalid_operation}

  defp apply_operation(draft, :add_step, params), do: add_step(draft, params)
  defp apply_operation(draft, :remove_step, params), do: remove_step(draft, params)
  defp apply_operation(draft, :update_step, params), do: update_step(draft, params)
  defp apply_operation(draft, :move_step, params), do: move_step(draft, params)
  defp apply_operation(draft, :move_steps, params), do: move_steps(draft, params)
  defp apply_operation(draft, :add_connection, params), do: add_connection(draft, params)
  defp apply_operation(draft, :remove_connection, params), do: remove_connection(draft, params)
  defp apply_operation(draft, :add_group, params), do: add_group(draft, params)
  defp apply_operation(draft, :update_group, params), do: update_group(draft, params)
  defp apply_operation(draft, :remove_group, params), do: remove_group(draft, params)

  defp apply_operation(draft, :set_group_membership, params),
    do: set_group_membership(draft, params)

  defp apply_operation(draft, :commit_drag_layout, params), do: commit_drag_layout(draft, params)
  defp apply_operation(draft, :duplicate_steps, params), do: duplicate_steps(draft, params)
  defp apply_operation(draft, :tidy_layout, params), do: tidy_layout(draft, params)
  defp apply_operation(draft, :remove_steps, params), do: remove_steps(draft, params)
  defp apply_operation(draft, :restore_steps, params), do: restore_steps(draft, params)
  defp apply_operation(draft, :restore_snapshot, params), do: restore_snapshot(draft, params)

  defp add_step(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, step} <- build_step_for_add(params),
         :ok <- ensure_step_absent(draft.steps, step.id),
         {:ok, groups} <-
           maybe_add_step_to_group(draft.step_groups, step.id, get_param(params, :group_id)),
         draft_with_step <- %{draft | steps: draft.steps ++ [step], step_groups: groups},
         {:ok, _new_connections, all_connections} <-
           build_connections_for_added_step(draft_with_step, step, params) do
      {:ok, %{draft_with_step | connections: all_connections},
       %{
         type: :remove_step,
         params: %{step_id: step.id},
         label: "Add Step"
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp remove_step(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, step_id} <- fetch_uuid_param(params, :step_id),
         {:ok, step} <- fetch_step(draft.steps, step_id) do
      {removed_connections, kept_connections} =
        Enum.split_with(
          draft.connections,
          &(&1.source_step_id == step_id or &1.target_step_id == step_id)
        )

      group_id = group_id_for_step(draft.step_groups, step_id)

      updated_groups =
        remove_step_ids_from_groups(draft.step_groups, [step_id])

      updated_steps =
        Enum.reject(draft.steps, &(&1.id == step_id))

      {:ok,
       %{
         draft
         | steps: updated_steps,
           connections: kept_connections,
           step_groups: updated_groups
       },
       %{
         type: :add_step,
         params: %{
           step: embed_attrs(step),
           connections: Enum.map(removed_connections, &embed_attrs/1),
           group_id: group_id
         },
         label: "Delete Step"
       }}
    end
  end

  defp update_step(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, step_id} <- fetch_uuid_param(params, :step_id),
         {:ok, step} <- fetch_step(draft.steps, step_id),
         changes = take_params(get_param(params, :changes, %{}), @step_update_fields),
         {:ok, normalized_changes} <- normalize_step_changes(step, changes),
         :ok <- ensure_non_empty_changes(normalized_changes) do
      old_values = take_struct_fields(step, Map.keys(normalized_changes))

      updated_step_attrs =
        step
        |> embed_attrs()
        |> Map.merge(normalized_changes)

      with {:ok, updated_step} <- build_step(updated_step_attrs) do
        updated_steps =
          replace_by_id(draft.steps, updated_step.id, updated_step)

        {:ok, %{draft | steps: updated_steps},
         %{
           type: :update_step,
           params: %{step_id: step_id, changes: old_values},
           label: "Edit Step"
         }}
      end
    end
  end

  defp move_step(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, step_id} <- fetch_uuid_param(params, :step_id),
         {:ok, step} <- fetch_step(draft.steps, step_id),
         {:ok, position} <- fetch_required_position(params, :position),
         {:ok, updated_step} <- build_step(Map.merge(embed_attrs(step), %{position: position})) do
      updated_steps = replace_by_id(draft.steps, step_id, updated_step)

      {:ok, %{draft | steps: updated_steps},
       %{
         type: :move_step,
         params: %{step_id: step_id, position: step.position},
         label: "Move Step"
       }}
    end
  end

  defp move_steps(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, step_positions} <- fetch_step_positions(params),
         {:ok, old_positions} <-
           fetch_existing_step_positions(draft.steps, Map.keys(step_positions)) do
      updated_steps =
        Enum.map(draft.steps, fn step ->
          case Map.fetch(step_positions, step.id) do
            {:ok, position} ->
              %{step | position: position}

            :error ->
              step
          end
        end)

      {:ok, %{draft | steps: updated_steps},
       %{
         type: :move_steps,
         params: %{step_positions: old_positions},
         label: "Move Steps"
       }}
    end
  end

  defp add_connection(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, connection} <- build_connection_for_add(params),
         :ok <- validate_connection_steps(draft.steps, connection),
         :ok <- validate_connection_shape(draft.connections, connection) do
      {:ok, %{draft | connections: draft.connections ++ [connection]},
       %{
         type: :remove_connection,
         params: %{connection_id: connection.id},
         label: "Add Connection"
       }}
    end
  end

  defp remove_connection(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, connection_id} <- fetch_uuid_param(params, :connection_id),
         {:ok, connection} <- fetch_connection(draft.connections, connection_id) do
      kept_connections = Enum.reject(draft.connections, &(&1.id == connection_id))

      {:ok, %{draft | connections: kept_connections},
       %{
         type: :add_connection,
         params: embed_attrs(connection),
         label: "Delete Connection"
       }}
    end
  end

  defp add_group(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, group} <- build_group_for_add(params),
         :ok <- ensure_group_absent(draft.step_groups, group.id),
         :ok <- validate_step_ids_exist(draft.steps, group.step_ids),
         {:ok, step_positions} <- fetch_optional_step_positions(params, :step_positions),
         {:ok, old_positions} <-
           fetch_existing_step_positions(draft.steps, Map.keys(step_positions)),
         old_memberships <- fetch_group_memberships(draft.step_groups, group.step_ids) do
      updated_groups =
        draft.step_groups
        |> remove_step_ids_from_groups(group.step_ids)
        |> Kernel.++([group])

      updated_steps =
        put_step_positions(draft.steps, step_positions)

      {:ok, %{draft | steps: updated_steps, step_groups: updated_groups},
       %{
         type: :remove_group,
         params: %{
           group_id: group.id,
           step_positions: old_positions,
           group_id_by_step_id: old_memberships
         },
         label: "Create Group"
       }}
    end
  end

  defp update_group(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, group_id} <- fetch_uuid_param(params, :group_id),
         {:ok, group} <- fetch_group(draft.step_groups, group_id),
         changes = take_params(get_param(params, :changes, %{}), @group_update_fields),
         {:ok, normalized_changes} <- normalize_group_changes(group, changes),
         :ok <- ensure_non_empty_changes(normalized_changes) do
      old_values = take_struct_fields(group, Map.keys(normalized_changes))

      updated_group_attrs =
        group
        |> embed_attrs()
        |> Map.merge(normalized_changes)

      with {:ok, updated_group} <- build_group(updated_group_attrs) do
        updated_groups = replace_by_id(draft.step_groups, group_id, updated_group)

        {:ok, %{draft | step_groups: updated_groups},
         %{
           type: :update_group,
           params: %{group_id: group_id, changes: old_values},
           label: "Edit Group"
         }}
      end
    end
  end

  defp remove_group(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, group_id} <- fetch_uuid_param(params, :group_id),
         {:ok, group} <- fetch_group(draft.step_groups, group_id),
         {:ok, restored_memberships} <- fetch_optional_memberships(params),
         :ok <- validate_membership_targets(draft.step_groups, restored_memberships, group_id),
         relative_positions <- fetch_member_positions(draft.steps, group.step_ids),
         absolute_positions <- build_group_absolute_positions(draft.steps, group),
         {:ok, override_positions} <- fetch_optional_step_positions(params, :step_positions),
         next_positions <- Map.merge(absolute_positions, override_positions),
         updated_steps <- put_step_positions(draft.steps, next_positions),
         groups_without_target <- Enum.reject(draft.step_groups, &(&1.id == group_id)),
         {:ok, updated_groups} <- apply_memberships(groups_without_target, restored_memberships) do
      {:ok, %{draft | steps: updated_steps, step_groups: updated_groups},
       %{
         type: :add_group,
         params: %{group: embed_attrs(group), step_positions: relative_positions},
         label: "Delete Group"
       }}
    end
  end

  defp set_group_membership(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, membership_map} <- resolve_membership_map(params),
         affected_step_ids <- Map.keys(membership_map),
         :ok <- validate_step_ids_exist(draft.steps, affected_step_ids),
         :ok <- validate_membership_targets(draft.step_groups, membership_map),
         {:ok, step_positions} <- fetch_optional_step_positions(params, :step_positions),
         {:ok, old_positions} <-
           fetch_existing_step_positions(draft.steps, Map.keys(step_positions)),
         old_memberships <- fetch_group_memberships(draft.step_groups, affected_step_ids),
         updated_steps <- put_step_positions(draft.steps, step_positions),
         {:ok, updated_groups} <- apply_memberships(draft.step_groups, membership_map) do
      {:ok, %{draft | steps: updated_steps, step_groups: updated_groups},
       %{
         type: :set_group_membership,
         params: %{
           step_ids: affected_step_ids,
           group_id_by_step_id: old_memberships,
           step_positions: old_positions
         },
         label: "Move Selection"
       }}
    end
  end

  defp commit_drag_layout(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, group_updates} <- fetch_group_updates(params, :groups),
         {:ok, step_positions} <- fetch_step_positions(params),
         {:ok, membership_map} <- fetch_optional_memberships(params),
         :ok <- validate_group_updates(draft.step_groups, group_updates),
         {:ok, old_group_positions} <-
           fetch_existing_group_positions(draft.step_groups, group_updates),
         {:ok, old_step_positions} <-
           fetch_existing_step_positions(draft.steps, Map.keys(step_positions)),
         affected_memberships <- Map.keys(membership_map),
         :ok <- validate_step_ids_exist(draft.steps, affected_memberships),
         :ok <- validate_membership_targets(draft.step_groups, membership_map),
         old_memberships <- fetch_group_memberships(draft.step_groups, affected_memberships),
         updated_steps <- put_step_positions(draft.steps, step_positions),
         updated_groups <- put_group_positions(draft.step_groups, group_updates),
         {:ok, final_groups} <- apply_memberships(updated_groups, membership_map) do
      {:ok, %{draft | steps: updated_steps, step_groups: final_groups},
       %{
         type: :commit_drag_layout,
         params: %{
           groups: old_group_positions,
           step_positions: old_step_positions,
           group_id_by_step_id: old_memberships
         },
         label: "Move Items"
       }}
    end
  end

  defp duplicate_steps(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, source_step_ids} <- fetch_step_ids(params, :step_ids),
         :ok <- validate_step_ids_exist(draft.steps, source_step_ids),
         {:ok, target_positions} <- fetch_optional_step_positions(params, :position_by_step_id),
         {:ok, target_memberships} <- fetch_optional_memberships(params, :group_id_by_step_id),
         :ok <- validate_membership_targets(draft.step_groups, target_memberships),
         source_steps <- fetch_steps!(draft.steps, source_step_ids),
         id_map <- Map.new(source_steps, fn step -> {step.id, Ecto.UUID.generate()} end),
         {:ok, duplicated_steps} <-
           build_duplicated_steps(source_steps, id_map, target_positions),
         {:ok, duplicated_connections} <-
           build_duplicated_connections(draft.connections, source_step_ids, id_map),
         duplicated_memberships <- translate_memberships(target_memberships, id_map),
         {:ok, groups_with_duplicates} <-
           apply_memberships(draft.step_groups, duplicated_memberships) do
      duplicated_ids = Enum.map(duplicated_steps, & &1.id)

      {:ok,
       %{
         draft
         | steps: draft.steps ++ duplicated_steps,
           connections: draft.connections ++ duplicated_connections,
           step_groups: groups_with_duplicates
       },
       %{
         type: :remove_steps,
         params: %{step_ids: duplicated_ids},
         label: "Duplicate Steps"
       }}
    end
  end

  defp tidy_layout(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, step_updates} <- fetch_step_updates_list(params, :steps),
         {:ok, group_updates} <- fetch_group_updates(params, :groups),
         {:ok, old_step_positions} <-
           fetch_existing_step_positions(draft.steps, Map.keys(step_updates)),
         {:ok, old_group_positions} <-
           fetch_existing_group_positions(draft.step_groups, group_updates),
         updated_steps <- put_step_positions(draft.steps, step_updates),
         updated_groups <- put_group_positions(draft.step_groups, group_updates) do
      {:ok, %{draft | steps: updated_steps, step_groups: updated_groups},
       %{
         type: :tidy_layout,
         params: %{
           steps: to_step_update_list(old_step_positions),
           groups: old_group_positions,
           label: get_param(params, :label, "Tidy Layout")
         },
         label: get_param(params, :label, "Tidy Layout")
       }}
    end
  end

  defp remove_steps(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, step_ids} <- fetch_step_ids(params, :step_ids),
         :ok <- validate_step_ids_exist(draft.steps, step_ids) do
      removed_steps = fetch_steps!(draft.steps, step_ids)

      {removed_connections, kept_connections} =
        Enum.split_with(draft.connections, fn connection ->
          connection.source_step_id in step_ids or connection.target_step_id in step_ids
        end)

      removed_memberships = fetch_group_memberships(draft.step_groups, step_ids)

      updated_steps = Enum.reject(draft.steps, &(&1.id in step_ids))
      updated_groups = remove_step_ids_from_groups(draft.step_groups, step_ids)

      {:ok,
       %{
         draft
         | steps: updated_steps,
           connections: kept_connections,
           step_groups: updated_groups
       },
       %{
         type: :restore_steps,
         params: %{
           steps: Enum.map(removed_steps, &embed_attrs/1),
           connections: Enum.map(removed_connections, &embed_attrs/1),
           group_id_by_step_id: removed_memberships
         },
         label: "Delete Steps"
       }}
    end
  end

  defp restore_steps(%WorkflowDefinitionVersion{} = draft, params) do
    with {:ok, steps} <- build_steps(get_param(params, :steps, [])),
         :ok <- validate_restored_steps_absent(draft.steps, steps),
         {:ok, memberships} <- fetch_optional_memberships(params),
         :ok <- validate_membership_targets(draft.step_groups, memberships),
         steps_by_id = Map.new(draft.steps ++ steps, &{&1.id, true}),
         {:ok, connections} <-
           build_connections(
             get_param(params, :connections, []),
             Map.keys(steps_by_id),
             draft.connections
           ),
         {:ok, updated_groups} <- apply_memberships(draft.step_groups, memberships) do
      step_ids = Enum.map(steps, & &1.id)

      {:ok,
       %{
         draft
         | steps: draft.steps ++ steps,
           connections: draft.connections ++ connections,
           step_groups: updated_groups
       },
       %{
         type: :remove_steps,
         params: %{step_ids: step_ids},
         label: "Restore Steps"
       }}
    end
  end

  defp restore_snapshot(%WorkflowDefinitionVersion{} = draft, params) do
    with snapshot when is_map(snapshot) <- get_param(params, :snapshot),
         attrs <- snapshot_attrs(snapshot, draft),
         {:ok, updated_draft} <- apply_draft_changeset(draft, attrs) do
      label = snapshot_label(params)

      {:ok, updated_draft,
       %{
         type: :restore_snapshot,
         params: %{snapshot: snapshot_attrs(draft), label: label},
         label: label
       }}
    else
      nil ->
        {:error, :invalid_snapshot}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_type(%{type: type}), do: normalize_type(type)
  defp normalize_type(%{"type" => type}), do: normalize_type(type)
  defp normalize_type(type) when is_atom(type), do: {:ok, type}

  defp normalize_type(type) when is_binary(type) do
    case Map.fetch(@string_operation_types, type) do
      {:ok, atom_type} -> {:ok, atom_type}
      :error -> {:error, :unsupported_operation}
    end
  end

  defp normalize_type(_type), do: {:error, :unsupported_operation}

  defp fetch_params(%{params: params}) when is_map(params), do: {:ok, params}
  defp fetch_params(%{"params" => params}) when is_map(params), do: {:ok, params}
  defp fetch_params(_operation), do: {:ok, %{}}

  defp build_step_for_add(params) do
    case get_param(params, :step) do
      nil ->
        with {:ok, type_id} <- fetch_binary_param(params, :type_id),
             {:ok, position} <- fetch_required_position(params, :position),
             {:ok, step_type} <- StepRegistry.get(type_id) do
          build_step(%{
            id: Ecto.UUID.generate(),
            type_id: type_id,
            name: step_type.name,
            config: StepRegistry.get_default_config(type_id),
            position: position,
            notes: nil
          })
        else
          {:error, :not_found} -> {:error, :unknown_step_type}
          {:error, _reason} = error -> error
        end

      step_attrs ->
        build_step(step_attrs)
    end
  end

  defp build_connection_for_add(params) do
    case get_param(params, :connection) do
      nil ->
        build_connection(%{
          id: get_param(params, :id, Ecto.UUID.generate()),
          source_step_id: get_param(params, :source_step_id),
          source_output: get_param(params, :source_output, @default_handle),
          target_step_id: get_param(params, :target_step_id),
          target_input: get_param(params, :target_input, @default_handle)
        })

      connection_attrs ->
        build_connection(connection_attrs)
    end
  end

  defp build_group_for_add(params) do
    case get_param(params, :group) do
      nil ->
        with {:ok, step_ids} <- fetch_step_ids(params, :step_ids),
             {:ok, position} <- fetch_required_bounds(params, :position) do
          build_group(%{
            id: Ecto.UUID.generate(),
            name: get_param(params, :name, "Group"),
            step_ids: step_ids,
            position: position,
            color: get_param(params, :color),
            font_size: get_param(params, :font_size, 14),
            collapsed: get_param(params, :collapsed, false)
          })
        end

      group_attrs ->
        build_group(group_attrs)
    end
  end

  defp build_step(attrs) do
    attrs
    |> normalize_step_attrs()
    |> then(&Step.changeset(%Step{}, &1))
    |> apply_step_changeset()
  end

  defp build_steps(attrs_list) when is_list(attrs_list) do
    attrs_list
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, steps} ->
      case build_step(attrs) do
        {:ok, step} -> {:cont, {:ok, steps ++ [step]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp build_steps(_attrs_list), do: {:error, :invalid_steps}

  defp build_connection(attrs) do
    attrs
    |> normalize_connection_attrs()
    |> then(&Connection.changeset(%Connection{}, &1))
    |> apply_connection_changeset()
  end

  defp build_connections(attrs_list, valid_step_ids, existing_connections)
       when is_list(attrs_list) do
    step_ids = MapSet.new(valid_step_ids)

    attrs_list
    |> Enum.reduce_while({:ok, existing_connections, []}, fn attrs,
                                                             {:ok, all_connections, built} ->
      with {:ok, connection} <- build_connection(attrs),
           :ok <- validate_connection_steps(step_ids, connection),
           :ok <- validate_connection_shape(all_connections, connection) do
        {:cont, {:ok, all_connections ++ [connection], built ++ [connection]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _all_connections, built} -> {:ok, built}
      {:error, _reason} = error -> error
    end
  end

  defp build_connections(_attrs_list, _valid_step_ids, _existing_connections),
    do: {:error, :invalid_connections}

  defp build_group(attrs) do
    attrs
    |> normalize_group_attrs()
    |> then(&StepGroup.changeset(%StepGroup{}, &1))
    |> apply_group_changeset()
  end

  defp apply_draft_changeset(%WorkflowDefinitionVersion{} = draft, attrs) when is_map(attrs) do
    draft
    |> WorkflowDefinitionVersion.save_changeset(attrs)
    |> apply_draft_version_changeset()
  end

  defp build_connections_for_added_step(%WorkflowDefinitionVersion{} = draft, step, params) do
    case get_param(params, :connections) do
      connections when is_list(connections) ->
        with {:ok, built_connections} <-
               build_connections(connections, Enum.map(draft.steps, & &1.id), draft.connections) do
          {:ok, built_connections, draft.connections ++ built_connections}
        end

      _ ->
        case get_param(params, :auto_connect) do
          nil ->
            {:ok, [], draft.connections}

          auto_connect when is_map(auto_connect) ->
            with {:ok, connection_attrs} <- build_auto_connect(step.id, auto_connect),
                 {:ok, connection} <- build_connection(connection_attrs),
                 :ok <- validate_connection_steps(draft.steps, connection),
                 :ok <- validate_connection_shape(draft.connections, connection) do
              {:ok, [connection], draft.connections ++ [connection]}
            end

          _ ->
            {:error, :invalid_auto_connect}
        end
    end
  end

  defp build_auto_connect(new_step_id, auto_connect) do
    source_step_id = get_param(auto_connect, :source_step_id)
    target_step_id = get_param(auto_connect, :target_step_id)

    case {source_step_id, target_step_id} do
      {source_step_id, nil} when is_binary(source_step_id) ->
        {:ok,
         %{
           id: Ecto.UUID.generate(),
           source_step_id: source_step_id,
           source_output: get_param(auto_connect, :source_output, @default_handle),
           target_step_id: new_step_id,
           target_input: get_param(auto_connect, :target_input, @default_handle)
         }}

      {nil, target_step_id} when is_binary(target_step_id) ->
        {:ok,
         %{
           id: Ecto.UUID.generate(),
           source_step_id: new_step_id,
           source_output: get_param(auto_connect, :source_output, @default_handle),
           target_step_id: target_step_id,
           target_input: get_param(auto_connect, :target_input, @default_handle)
         }}

      _ ->
        {:error, :invalid_auto_connect}
    end
  end

  defp normalize_step_changes(step, changes) when is_map(changes) do
    case Map.fetch(changes, :position) do
      {:ok, position} ->
        with {:ok, normalized_position} <- normalize_position(position, [:x, :y]) do
          {:ok, Map.put(changes, :position, normalized_position)}
        end

      :error ->
        case Map.fetch(changes, "position") do
          {:ok, position} ->
            with {:ok, normalized_position} <- normalize_position(position, [:x, :y]) do
              {:ok, Map.put(changes, :position, normalized_position)}
            end

          :error ->
            {:ok, changes}
        end
    end
    |> case do
      {:ok, normalized_changes} ->
        merged_changes =
          case Map.fetch(normalized_changes, :position) do
            {:ok, position} ->
              Map.put(normalized_changes, :position, Map.merge(step.position || %{}, position))

            :error ->
              normalized_changes
          end

        {:ok, merged_changes}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_group_changes(group, changes) when is_map(changes) do
    case Map.fetch(changes, :position) do
      {:ok, position} ->
        with {:ok, normalized_position} <-
               normalize_partial_position(position, [:x, :y, :width, :height]) do
          {:ok,
           Map.put(changes, :position, Map.merge(group.position || %{}, normalized_position))}
        end

      :error ->
        case Map.fetch(changes, "position") do
          {:ok, position} ->
            with {:ok, normalized_position} <-
                   normalize_partial_position(position, [:x, :y, :width, :height]) do
              {:ok,
               Map.put(changes, :position, Map.merge(group.position || %{}, normalized_position))}
            end

          :error ->
            {:ok, changes}
        end
    end
  end

  defp fetch_optional_step_positions(params, key) do
    case get_param(params, key) do
      nil -> {:ok, %{}}
      value -> normalize_step_positions(value)
    end
  end

  defp fetch_step_positions(params) do
    case get_param(params, :step_positions) do
      value when is_map(value) -> normalize_step_positions(value)
      _ -> {:error, :invalid_step_positions}
    end
  end

  defp normalize_step_positions(step_positions) when is_map(step_positions) do
    step_positions
    |> Enum.reduce_while({:ok, %{}}, fn {step_id, position}, {:ok, acc} ->
      with {:ok, uuid} <- validate_uuid(step_id, :step_id),
           {:ok, normalized_position} <- normalize_position(position, [:x, :y]) do
        {:cont, {:ok, Map.put(acc, uuid, normalized_position)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_step_positions(_step_positions), do: {:error, :invalid_step_positions}

  defp fetch_group_updates(params, key) do
    case get_param(params, key, []) do
      updates when is_list(updates) ->
        updates
        |> Enum.reduce_while({:ok, []}, fn update, {:ok, acc} ->
          with {:ok, group_id} <- fetch_uuid_param(update, :group_id),
               {:ok, position} <- fetch_required_bounds(update, :position) do
            {:cont, {:ok, acc ++ [%{group_id: group_id, position: position}]}}
          else
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      _ ->
        {:error, :invalid_group_updates}
    end
  end

  defp fetch_step_updates_list(params, key) do
    case get_param(params, key, []) do
      updates when is_list(updates) ->
        updates
        |> Enum.reduce_while({:ok, %{}}, fn update, {:ok, acc} ->
          with {:ok, step_id} <- fetch_uuid_param(update, :step_id),
               {:ok, position} <- fetch_required_position(update, :position) do
            {:cont, {:ok, Map.put(acc, step_id, position)}}
          else
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      _ ->
        {:error, :invalid_step_updates}
    end
  end

  defp fetch_optional_memberships(params, key \\ :group_id_by_step_id) do
    case get_param(params, key) do
      nil -> {:ok, %{}}
      value -> normalize_memberships(value)
    end
  end

  defp normalize_memberships(memberships) when is_map(memberships) do
    memberships
    |> Enum.reduce_while({:ok, %{}}, fn {step_id, group_id}, {:ok, acc} ->
      with {:ok, step_uuid} <- validate_uuid(step_id, :step_id),
           {:ok, group_uuid} <- normalize_optional_uuid(group_id, :group_id) do
        {:cont, {:ok, Map.put(acc, step_uuid, group_uuid)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_memberships(_memberships), do: {:error, :invalid_group_memberships}

  defp resolve_membership_map(params) do
    case get_param(params, :group_id_by_step_id) do
      memberships when is_map(memberships) ->
        normalize_memberships(memberships)

      _ ->
        with {:ok, step_ids} <- fetch_step_ids(params, :step_ids),
             {:ok, group_id} <- normalize_optional_uuid(get_param(params, :group_id), :group_id) do
          {:ok, Map.new(step_ids, &{&1, group_id})}
        end
    end
  end

  defp fetch_step_ids(params, key) do
    case get_param(params, key) do
      ids when is_list(ids) ->
        ids
        |> Enum.reduce_while({:ok, []}, fn step_id, {:ok, acc} ->
          case validate_uuid(step_id, :step_id) do
            {:ok, uuid} -> {:cont, {:ok, acc ++ [uuid]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, step_ids} -> {:ok, Enum.uniq(step_ids)}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, :invalid_step_ids}
    end
  end

  defp fetch_existing_step_positions(steps, step_ids) do
    step_ids
    |> Enum.reduce_while({:ok, %{}}, fn step_id, {:ok, positions} ->
      with {:ok, uuid} <- validate_uuid(step_id, :step_id),
           {:ok, step} <- fetch_step(steps, uuid) do
        {:cont, {:ok, Map.put(positions, uuid, step.position)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_existing_group_positions(groups, group_updates) do
    group_updates
    |> Enum.reduce_while({:ok, []}, fn %{group_id: group_id}, {:ok, positions} ->
      with {:ok, group} <- fetch_group(groups, group_id) do
        {:cont, {:ok, positions ++ [%{group_id: group.id, position: group.position}]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_group_memberships(groups, step_ids) do
    membership_by_step_id =
      groups
      |> Enum.reduce(%{}, fn group, acc ->
        Enum.reduce(group.step_ids, acc, fn step_id, memberships ->
          Map.put_new(memberships, step_id, group.id)
        end)
      end)

    Map.new(step_ids, fn step_id -> {step_id, Map.get(membership_by_step_id, step_id)} end)
  end

  defp fetch_member_positions(steps, step_ids) do
    steps
    |> Enum.filter(&(&1.id in step_ids))
    |> Map.new(fn step -> {step.id, step.position} end)
  end

  defp build_group_absolute_positions(steps, group) do
    group_origin = group.position || %{}

    steps
    |> Enum.filter(&(&1.id in group.step_ids))
    |> Map.new(fn step ->
      {
        step.id,
        %{
          "x" => position_value(step.position, :x) + position_value(group_origin, :x),
          "y" => position_value(step.position, :y) + position_value(group_origin, :y)
        }
      }
    end)
  end

  defp build_duplicated_steps(source_steps, id_map, target_positions) do
    source_steps
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, acc} ->
      attrs =
        step
        |> embed_attrs()
        |> Map.put(:id, Map.fetch!(id_map, step.id))
        |> Map.put(:position, Map.get(target_positions, step.id, step.position))

      case build_step(attrs) do
        {:ok, duplicated_step} -> {:cont, {:ok, acc ++ [duplicated_step]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp build_duplicated_connections(connections, source_step_ids, id_map) do
    source_step_id_set = MapSet.new(source_step_ids)

    connections
    |> Enum.filter(fn connection ->
      MapSet.member?(source_step_id_set, connection.source_step_id) and
        MapSet.member?(source_step_id_set, connection.target_step_id)
    end)
    |> Enum.reduce_while({:ok, []}, fn connection, {:ok, acc} ->
      attrs =
        connection
        |> embed_attrs()
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:source_step_id, Map.fetch!(id_map, connection.source_step_id))
        |> Map.put(:target_step_id, Map.fetch!(id_map, connection.target_step_id))

      case build_connection(attrs) do
        {:ok, duplicated_connection} -> {:cont, {:ok, acc ++ [duplicated_connection]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp translate_memberships(memberships, id_map) do
    memberships
    |> Enum.reduce(%{}, fn {source_step_id, group_id}, acc ->
      case Map.fetch(id_map, source_step_id) do
        {:ok, duplicated_step_id} -> Map.put(acc, duplicated_step_id, group_id)
        :error -> acc
      end
    end)
  end

  defp apply_memberships(groups, membership_map) when map_size(membership_map) == 0,
    do: {:ok, groups}

  defp apply_memberships(groups, membership_map) do
    affected_step_ids = Map.keys(membership_map)
    groups_without_affected = remove_step_ids_from_groups(groups, affected_step_ids)

    membership_map
    |> Enum.reduce_while({:ok, groups_without_affected}, fn
      {_step_id, nil}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      {step_id, group_id}, {:ok, acc} ->
        case fetch_group(acc, group_id) do
          {:ok, group} ->
            updated_group =
              %{group | step_ids: Enum.uniq(group.step_ids ++ [step_id])}

            {:cont, {:ok, replace_by_id(acc, group_id, updated_group)}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end)
  end

  defp validate_connection_steps(steps, %Connection{} = connection) when is_list(steps) do
    step_ids = MapSet.new(Enum.map(steps, & &1.id))
    validate_connection_steps(step_ids, connection)
  end

  defp validate_connection_steps(%MapSet{} = step_ids, %Connection{} = connection) do
    cond do
      not MapSet.member?(step_ids, connection.source_step_id) -> {:error, :source_step_not_found}
      not MapSet.member?(step_ids, connection.target_step_id) -> {:error, :target_step_not_found}
      true -> :ok
    end
  end

  defp validate_connection_shape(existing_connections, %Connection{} = connection) do
    cond do
      connection.source_step_id == connection.target_step_id ->
        {:error, :self_connection}

      Enum.any?(existing_connections, &duplicate_connection?(&1, connection)) ->
        {:error, :duplicate_connection}

      true ->
        :ok
    end
  end

  defp validate_step_ids_exist(steps, step_ids) do
    step_id_set = MapSet.new(Enum.map(steps, & &1.id))

    case Enum.find(step_ids, fn step_id -> not MapSet.member?(step_id_set, step_id) end) do
      nil -> :ok
      _step_id -> {:error, :step_not_found}
    end
  end

  defp validate_membership_targets(groups, memberships, ignored_group_id \\ nil)

  defp validate_membership_targets(_groups, memberships, _ignored_group_id)
       when map_size(memberships) == 0,
       do: :ok

  defp validate_membership_targets(groups, memberships, ignored_group_id) do
    group_id_set =
      groups
      |> Enum.reject(&(&1.id == ignored_group_id))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    case Enum.find(memberships, fn
           {_step_id, nil} -> false
           {_step_id, group_id} -> not MapSet.member?(group_id_set, group_id)
         end) do
      nil -> :ok
      _membership -> {:error, :group_not_found}
    end
  end

  defp validate_group_updates(groups, updates) do
    group_ids = MapSet.new(Enum.map(groups, & &1.id))

    case Enum.find(updates, fn %{group_id: group_id} ->
           not MapSet.member?(group_ids, group_id)
         end) do
      nil -> :ok
      _update -> {:error, :group_not_found}
    end
  end

  defp validate_restored_steps_absent(existing_steps, restored_steps) do
    existing_ids = MapSet.new(Enum.map(existing_steps, & &1.id))

    case Enum.find(restored_steps, fn step -> MapSet.member?(existing_ids, step.id) end) do
      nil -> :ok
      _step -> {:error, :step_already_exists}
    end
  end

  defp maybe_add_step_to_group(groups, _step_id, nil), do: {:ok, groups}

  defp maybe_add_step_to_group(groups, step_id, group_id) do
    with {:ok, group_uuid} <- normalize_optional_uuid(group_id, :group_id),
         {:ok, group} <- fetch_group(groups, group_uuid) do
      updated_group = %{group | step_ids: Enum.uniq(group.step_ids ++ [step_id])}
      {:ok, replace_by_id(groups, group_uuid, updated_group)}
    end
  end

  defp remove_step_ids_from_groups(groups, step_ids) do
    step_id_set = MapSet.new(step_ids)

    Enum.map(groups, fn group ->
      filtered_step_ids =
        Enum.reject(group.step_ids, &MapSet.member?(step_id_set, &1))

      %{group | step_ids: filtered_step_ids}
    end)
  end

  defp put_step_positions(steps, step_positions) when map_size(step_positions) == 0, do: steps

  defp put_step_positions(steps, step_positions) do
    Enum.map(steps, fn step ->
      case Map.fetch(step_positions, step.id) do
        {:ok, position} -> %{step | position: position}
        :error -> step
      end
    end)
  end

  defp put_group_positions(groups, updates) when is_list(updates) do
    positions_by_group_id =
      Map.new(updates, fn %{group_id: group_id, position: position} -> {group_id, position} end)

    Enum.map(groups, fn group ->
      case Map.fetch(positions_by_group_id, group.id) do
        {:ok, position} -> %{group | position: position}
        :error -> group
      end
    end)
  end

  defp fetch_step(steps, step_id) do
    case Enum.find(steps, &(&1.id == step_id)) do
      %Step{} = step -> {:ok, step}
      nil -> {:error, :step_not_found}
    end
  end

  defp fetch_steps!(steps, step_ids) do
    step_ids
    |> Enum.map(fn step_id ->
      Enum.find(steps, &(&1.id == step_id))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_connection(connections, connection_id) do
    case Enum.find(connections, &(&1.id == connection_id)) do
      %Connection{} = connection -> {:ok, connection}
      nil -> {:error, :connection_not_found}
    end
  end

  defp fetch_group(groups, group_id) do
    case Enum.find(groups, &(&1.id == group_id)) do
      %StepGroup{} = group -> {:ok, group}
      nil -> {:error, :group_not_found}
    end
  end

  defp ensure_step_absent(steps, step_id) do
    case Enum.any?(steps, &(&1.id == step_id)) do
      true -> {:error, :step_already_exists}
      false -> :ok
    end
  end

  defp ensure_group_absent(groups, group_id) do
    case Enum.any?(groups, &(&1.id == group_id)) do
      true -> {:error, :group_already_exists}
      false -> :ok
    end
  end

  defp ensure_non_empty_changes(changes) when map_size(changes) == 0,
    do: {:error, :invalid_changes}

  defp ensure_non_empty_changes(_changes), do: :ok

  defp duplicate_connection?(left, right) do
    left.source_step_id == right.source_step_id and
      left.source_output == right.source_output and
      left.target_step_id == right.target_step_id and
      left.target_input == right.target_input
  end

  defp group_id_for_step(groups, step_id) do
    case Enum.find(groups, fn group -> step_id in group.step_ids end) do
      %StepGroup{} = group -> group.id
      nil -> nil
    end
  end

  defp replace_by_id(items, id, replacement) do
    Enum.map(items, fn item ->
      case item.id == id do
        true -> replacement
        false -> item
      end
    end)
  end

  defp fetch_uuid_param(params, key) do
    params
    |> get_param(key)
    |> validate_uuid(key)
  end

  defp fetch_binary_param(params, key) do
    case get_param(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_param, key}}
    end
  end

  defp validate_uuid(value, field) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, field}}
    end
  end

  defp validate_uuid(_value, field), do: {:error, {:invalid_uuid, field}}

  defp normalize_optional_uuid(nil, _field), do: {:ok, nil}
  defp normalize_optional_uuid(value, field), do: validate_uuid(value, field)

  defp fetch_required_position(params, key) do
    params
    |> get_param(key)
    |> normalize_position([:x, :y])
  end

  defp fetch_required_bounds(params, key) do
    params
    |> get_param(key)
    |> normalize_position([:x, :y, :width, :height])
  end

  defp normalize_position(position, fields) do
    normalize_position_fields(position, fields)
  end

  defp normalize_partial_position(position, fields) do
    case position do
      map when is_map(map) ->
        map
        |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
          cond do
            is_atom(key) and key in fields ->
              {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}

            is_binary(key) and key in Enum.map(fields, &Atom.to_string/1) ->
              {:cont, {:ok, Map.put(acc, key, value)}}

            true ->
              {:cont, {:ok, acc}}
          end
        end)

      _ ->
        {:error, :invalid_position}
    end
  end

  defp normalize_position_fields(position, fields) when is_map(position) do
    fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      case fetch_map_value(position, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, Atom.to_string(field), value)}}
        :error -> {:halt, {:error, :invalid_position}}
      end
    end)
  end

  defp normalize_position_fields(_position, _fields), do: {:error, :invalid_position}

  defp normalize_step_attrs(attrs) when is_map(attrs) do
    attrs
    |> take_params([:id, :type_id, :name, :config, :position, :notes])
    |> maybe_normalize_position(:position, [:x, :y])
  end

  defp normalize_connection_attrs(attrs) when is_map(attrs) do
    take_params(attrs, [:id, :source_step_id, :source_output, :target_step_id, :target_input])
  end

  defp normalize_group_attrs(attrs) when is_map(attrs) do
    attrs
    |> take_params([:id, :name, :step_ids, :position, :color, :font_size, :collapsed])
    |> maybe_normalize_position(:position, [:x, :y, :width, :height])
  end

  defp maybe_normalize_position(attrs, key, fields) do
    case Map.fetch(attrs, key) do
      {:ok, position} ->
        case normalize_position(position, fields) do
          {:ok, normalized_position} -> Map.put(attrs, key, normalized_position)
          {:error, _reason} -> attrs
        end

      :error ->
        attrs
    end
  end

  defp fetch_map_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp get_param(params, key, default \\ nil)

  defp get_param(params, key, default) when is_map(params) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key), default)
    end
  end

  defp get_param(_params, _key, default), do: default

  defp take_params(params, allowed_fields) when is_map(params) do
    Enum.reduce(allowed_fields, %{}, fn field, acc ->
      case Map.fetch(params, field) do
        {:ok, value} ->
          Map.put(acc, field, value)

        :error ->
          case Map.fetch(params, Atom.to_string(field)) do
            {:ok, value} -> Map.put(acc, field, value)
            :error -> acc
          end
      end
    end)
  end

  defp take_params(_params, _allowed_fields), do: %{}

  defp take_struct_fields(struct, fields) do
    struct
    |> embed_attrs()
    |> Map.take(fields)
  end

  defp to_step_update_list(step_positions) do
    step_positions
    |> Enum.map(fn {step_id, position} -> %{step_id: step_id, position: position} end)
  end

  defp snapshot_attrs(snapshot, %WorkflowDefinitionVersion{} = draft) when is_map(snapshot) do
    %{
      steps: get_param(snapshot, :steps, []),
      connections: get_param(snapshot, :connections, []),
      step_groups: get_param(snapshot, :step_groups, []),
      viewport: get_param(snapshot, :viewport, draft.viewport || %{}),
      settings: get_param(snapshot, :settings, draft.settings || %{})
    }
  end

  defp snapshot_attrs(%WorkflowDefinitionVersion{} = draft) do
    %{
      steps: Enum.map(draft.steps, &embed_attrs/1),
      connections: Enum.map(draft.connections, &embed_attrs/1),
      step_groups: Enum.map(draft.step_groups, &embed_attrs/1),
      viewport: draft.viewport,
      settings: draft.settings
    }
  end

  defp snapshot_label(params) do
    case get_param(params, :label) do
      label when is_binary(label) and label != "" -> label
      _ -> "Apply Revision"
    end
  end

  defp position_value(position, key) when is_map(position) do
    case fetch_map_value(position, key) do
      {:ok, value} when is_number(value) -> value
      _ -> 0
    end
  end

  defp position_value(_position, _key), do: 0

  defp embed_attrs(%_{} = embed) do
    embed
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end

  defp apply_step_changeset(changeset) do
    case Changeset.apply_action(changeset, :insert) do
      {:ok, step} -> {:ok, step}
      {:error, invalid_changeset} -> {:error, {:invalid_step, invalid_changeset}}
    end
  end

  defp apply_connection_changeset(changeset) do
    case Changeset.apply_action(changeset, :insert) do
      {:ok, connection} -> {:ok, connection}
      {:error, invalid_changeset} -> {:error, {:invalid_connection, invalid_changeset}}
    end
  end

  defp apply_group_changeset(changeset) do
    case Changeset.apply_action(changeset, :insert) do
      {:ok, group} -> {:ok, group}
      {:error, invalid_changeset} -> {:error, {:invalid_group, invalid_changeset}}
    end
  end

  defp apply_draft_version_changeset(changeset) do
    case Changeset.apply_action(changeset, :update) do
      {:ok, draft} -> {:ok, draft}
      {:error, invalid_changeset} -> {:error, {:invalid_snapshot, invalid_changeset}}
    end
  end
end
