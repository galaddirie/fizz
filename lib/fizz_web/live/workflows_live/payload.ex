defmodule FizzWeb.WorkflowsLive.Payload do
  @moduledoc false

  alias Fizz.Steps.Type
  alias Fizz.Workflows.Embeds.{Connection, Step, StepGroup}
  alias Fizz.Workflows.{WorkflowDefinition, WorkflowDefinitionVersion}

  @spec workflow(WorkflowDefinition.t(), WorkflowDefinitionVersion.t(), String.t() | nil) :: map()
  def workflow(
        %WorkflowDefinition{} = definition,
        %WorkflowDefinitionVersion{} = draft,
        project_name
      ) do
    %{
      id: definition.id,
      project_id: definition.project_id,
      name: definition.name,
      description: definition.description,
      created_by_user_id: definition.created_by_user_id,
      archived_at: datetime(definition.archived_at),
      latest_version: latest_version(definition, draft),
      published_version_id: published_version_id(definition),
      inserted_at: datetime(definition.inserted_at),
      updated_at: datetime(definition.updated_at),
      draft: draft(draft),
      project: %{name: project_name}
    }
  end

  @spec draft(WorkflowDefinitionVersion.t()) :: map()
  def draft(%WorkflowDefinitionVersion{} = draft) do
    %{
      id: draft.id,
      workflow_definition_id: draft.workflow_definition_id,
      version: draft.version,
      status: version_status(draft.status),
      steps: Enum.map(draft.steps, &encode_step/1),
      connections: Enum.map(draft.connections, &encode_connection/1),
      step_groups: Enum.map(draft.step_groups, &encode_group/1),
      settings: draft.settings || %{},
      viewport: draft.viewport || %{},
      compiled_hash: draft.compiled_hash,
      published_at: datetime(draft.published_at),
      published_by_user_id: draft.published_by_user_id,
      inserted_at: datetime(draft.inserted_at),
      updated_at: datetime(draft.updated_at)
    }
  end

  @spec step_type(Type.t()) :: map()
  def step_type(%Type{} = type) do
    %{
      id: type.id,
      name: type.name,
      description: type.description,
      category: type.category,
      icon: type.icon,
      step_kind: Atom.to_string(type.step_kind),
      node_role: Atom.to_string(type.node_role),
      config_schema: type.config_schema || %{},
      input_schema: type.input_schema || %{},
      output_schema: type.output_schema || %{},
      subnode_slots: type.subnode_slots || []
    }
  end

  @spec snapshot_attrs(WorkflowDefinitionVersion.t()) :: map()
  def snapshot_attrs(%WorkflowDefinitionVersion{} = draft) do
    %{
      steps: Enum.map(draft.steps, &embed_attrs/1),
      connections: Enum.map(draft.connections, &embed_attrs/1),
      step_groups: Enum.map(draft.step_groups, &embed_attrs/1),
      viewport: draft.viewport || %{},
      settings: draft.settings || %{}
    }
  end

  @spec published_versions(WorkflowDefinition.t()) :: [map()]
  def published_versions(%WorkflowDefinition{versions: versions}) when is_list(versions) do
    versions
    |> Enum.filter(&(&1.status == :published))
    |> Enum.map(fn version ->
      %{
        id: version.id,
        version: version.version,
        published_at: datetime(version.published_at)
      }
    end)
  end

  def published_versions(_definition), do: []

  @spec datetime(DateTime.t() | NaiveDateTime.t() | term()) :: String.t() | term() | nil
  def datetime(nil), do: nil
  def datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def datetime(value), do: value

  defp latest_version(
         %WorkflowDefinition{versions: versions},
         %WorkflowDefinitionVersion{} = draft
       )
       when is_list(versions) do
    versions
    |> Enum.map(& &1.version)
    |> List.insert_at(0, draft.version)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp latest_version(_definition, %WorkflowDefinitionVersion{version: version}), do: version
  defp latest_version(_definition, _draft), do: nil

  defp published_version_id(%WorkflowDefinition{versions: versions}) when is_list(versions) do
    versions
    |> Enum.filter(&(&1.status == :published))
    |> Enum.max_by(& &1.version, fn -> nil end)
    |> case do
      %WorkflowDefinitionVersion{id: id} -> id
      nil -> nil
    end
  end

  defp published_version_id(_definition), do: nil

  defp version_status(status) when is_atom(status), do: Atom.to_string(status)
  defp version_status(status) when is_binary(status), do: status

  defp encode_step(%Step{} = step) do
    %{
      id: step.id,
      type_id: step.type_id,
      name: step.name,
      config: step.config || %{},
      position: step.position || %{},
      notes: step.notes
    }
  end

  defp encode_connection(%Connection{} = connection) do
    %{
      id: connection.id,
      source_step_id: connection.source_step_id,
      source_output: connection.source_output,
      target_step_id: connection.target_step_id,
      target_input: connection.target_input
    }
  end

  defp encode_group(%StepGroup{} = group) do
    %{
      id: group.id,
      name: group.name,
      step_ids: group.step_ids || [],
      position: group.position || %{},
      color: group.color,
      font_size: group.font_size,
      collapsed: group.collapsed
    }
  end

  defp embed_attrs(%_{} = embed) do
    embed
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end
end
