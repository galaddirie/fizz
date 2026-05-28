defmodule FizzWeb.WorkflowsLive.Payload do
  @moduledoc false

  alias Fizz.Integrations.Steps.Type, as: StepType
  alias Fizz.Workflows.DraftValidator
  alias Fizz.Workflows.Embeds.{Connection, Step, StepGroup}
  alias Fizz.Workflows.{WorkflowDefinition, WorkflowDefinitionVersion, WorkflowRun}

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

  @spec step_type(StepType.t()) :: map()
  def step_type(%StepType{} = type) do
    %{
      id: type.id,
      name: type.name,
      description: type.description,
      category: type.category,
      icon: type.icon,
      step_kind: Atom.to_string(type.step_kind),
      config_schema: type.config_schema || %{},
      input_schema: type.input_schema || %{},
      output_schema: type.output_schema || %{}
    }
  end

  @spec node_library_item(StepType.t()) :: map()
  def node_library_item(%StepType{} = type) do
    %{
      type_id: type.id,
      name: type.name,
      description: type.description,
      icon: type.icon,
      category: type.category,
      step_kind: Atom.to_string(type.step_kind),
      input_schema: type.input_schema || %{},
      output_schema: type.output_schema || %{}
    }
  end

  @spec execution(WorkflowRun.t()) :: map()
  def execution(%WorkflowRun{} = run) do
    %{
      id: run.id,
      workflow_definition_id: run.workflow_definition_id,
      workflow_definition_version_id: run.workflow_definition_version_id,
      project_id: run.project_id,
      status: execution_status(run.status),
      trigger: %{
        type: trigger_type(run.triggered_by),
        data: run.triggered_by || %{}
      },
      triggered_by: run.triggered_by || %{},
      input: run.input || %{},
      output: run.output,
      error: execution_error(run.error),
      metadata: %{},
      compiled_hash: run.compiled_hash,
      triggered_by_user_id: triggered_by_user_id(run.triggered_by),
      started_at: datetime(run.started_at),
      completed_at: datetime(run.completed_at),
      inserted_at: datetime(run.inserted_at),
      updated_at: datetime(run.updated_at)
    }
  end

  @spec execution_status(atom() | String.t()) :: String.t()
  def execution_status(:pending), do: "pending"
  def execution_status(:running), do: "running"
  def execution_status(:sleeping), do: "paused"
  def execution_status(:passivated), do: "paused"
  def execution_status(:completed), do: "completed"
  def execution_status(:failed), do: "failed"
  def execution_status(:cancelled), do: "cancelled"
  def execution_status(:continued), do: "completed"
  def execution_status(status) when is_binary(status), do: status
  def execution_status(status), do: Atom.to_string(status)

  @spec execution_error(term()) :: map() | nil
  def execution_error(nil), do: nil

  def execution_error(%{} = error) do
    %{
      type: Map.get(error, :type) || Map.get(error, "type") || "runtime_error",
      message: Map.get(error, :message) || Map.get(error, "message") || inspect(error),
      details: error
    }
  end

  def execution_error(error) do
    %{type: "runtime_error", message: inspect(error), details: %{}}
  end

  @spec validation_error(DraftValidator.ValidationError.t()) :: map()
  def validation_error(%DraftValidator.ValidationError{} = error) do
    %{
      step_id: error.step_id,
      field: error.field,
      message: error.message,
      severity: Atom.to_string(error.severity),
      code: Atom.to_string(error.code)
    }
  end

  @spec validation_errors([DraftValidator.ValidationError.t()]) :: [map()]
  def validation_errors(errors) when is_list(errors) do
    Enum.map(errors, &validation_error/1)
  end

  @spec validation_error_map([DraftValidator.ValidationError.t()], String.t()) :: map()
  def validation_error_map(errors, global_key) when is_list(errors) and is_binary(global_key) do
    Enum.group_by(errors, fn error -> error.step_id || global_key end, & &1)
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

  defp trigger_type(%{} = triggered_by) do
    Map.get(triggered_by, :type) ||
      Map.get(triggered_by, "type") ||
      Map.get(triggered_by, :kind) ||
      Map.get(triggered_by, "kind") ||
      "manual"
  end

  defp trigger_type(_triggered_by), do: "manual"

  defp triggered_by_user_id(%{} = triggered_by) do
    Map.get(triggered_by, :user_id) || Map.get(triggered_by, "user_id")
  end

  defp triggered_by_user_id(_triggered_by), do: nil

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
