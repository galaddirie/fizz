defmodule Fizz.Workflows.WorkflowDefinitionVersion do
  use Fizz.Schema

  alias Fizz.Graph
  alias Fizz.Integrations.Steps.Registry, as: StepRegistry
  alias Fizz.Workflows.Embeds.{Connection, Step, StepGroup}
  alias Fizz.Workflows.PublishValidation
  alias Fizz.Workflows.WorkflowDefinition

  @type t :: %__MODULE__{}

  @statuses [:draft, :published, :archived]
  @default_viewport %{"x" => 0, "y" => 0, "zoom" => 1.0}

  schema "workflow_definition_versions" do
    field :version, :integer
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :viewport, :map, default: @default_viewport
    field :settings, :map, default: %{}
    field :compiled_hash, :string
    field :published_at, :utc_datetime_usec
    field :published_by_user_id, :string

    belongs_to :workflow_definition, WorkflowDefinition

    embeds_many :steps, Step, on_replace: :delete
    embeds_many :connections, Connection, on_replace: :delete
    embeds_many :step_groups, StepGroup, on_replace: :delete

    timestamps()
  end

  def default_viewport, do: @default_viewport

  @doc false
  def save_changeset(version, attrs) do
    changeset(version, attrs, validation_mode: :save)
  end

  @doc false
  def publish_changeset(version, attrs) do
    changeset(version, attrs, validation_mode: :publish)
  end

  @doc false
  def changeset(version, attrs, opts \\ []) do
    validation_mode = Keyword.get(opts, :validation_mode, :save)

    version
    |> cast(attrs, [
      :workflow_definition_id,
      :version,
      :status,
      :viewport,
      :settings,
      :compiled_hash,
      :published_at,
      :published_by_user_id
    ])
    |> validate_required([:workflow_definition_id, :version, :status, :viewport, :settings])
    |> validate_number(:version, greater_than: 0)
    |> cast_embed(:steps, with: &Step.changeset/2)
    |> cast_embed(:connections, with: &Connection.changeset/2)
    |> cast_embed(:step_groups, with: &StepGroup.changeset/2)
    |> validate_map_field(:viewport)
    |> validate_map_field(:settings)
    |> validate_unique_embed_ids(:steps, "step")
    |> validate_unique_embed_ids(:connections, "connection")
    |> validate_step_type_ids()
    |> validate_connection_step_refs()
    |> validate_step_group_refs()
    |> validate_non_overlapping_step_groups()
    |> validate_acyclic_graph()
    |> maybe_validate_for_publish(validation_mode)
    |> foreign_key_constraint(:workflow_definition_id)
    |> unique_constraint(:version, name: :workflow_definition_versions_definition_version_index)
    |> check_constraint(:status, name: :workflow_definition_versions_status_check)
  end

  defp maybe_validate_for_publish(changeset, :publish) do
    changeset
    |> validate_required([:compiled_hash, :published_at, :published_by_user_id])
    |> validate_step_configs()
    |> validate_has_entry_step()
    |> validate_expression_integrity()
    |> validate_credential_declarations()
  end

  defp maybe_validate_for_publish(changeset, _validation_mode), do: changeset

  defp validate_map_field(changeset, field) do
    case get_field(changeset, field) do
      value when is_map(value) ->
        changeset

      _ ->
        add_error(changeset, field, "must be a map")
    end
  end

  defp validate_unique_embed_ids(changeset, field, label) do
    duplicates =
      changeset
      |> get_field(field, [])
      |> Enum.map(& &1.id)
      |> Enum.reject(&is_nil/1)
      |> duplicate_values()

    case duplicates do
      [] ->
        changeset

      duplicate_ids ->
        add_error(
          changeset,
          field,
          "contains duplicate #{label} ids: #{Enum.join(duplicate_ids, ", ")}"
        )
    end
  end

  defp validate_step_type_ids(changeset) do
    unknown_types =
      changeset
      |> get_field(:steps, [])
      |> Enum.reduce([], fn step, errors ->
        case StepRegistry.get(step.type_id) do
          {:ok, _type} -> errors
          {:error, :not_found} -> ["#{step.id} (#{step.type_id})" | errors]
        end
      end)
      |> Enum.reverse()

    case unknown_types do
      [] ->
        changeset

      _ ->
        add_error(
          changeset,
          :steps,
          "contains unknown step types: #{Enum.join(unknown_types, ", ")}"
        )
    end
  end

  defp validate_connection_step_refs(changeset) do
    step_ids =
      changeset
      |> get_field(:steps, [])
      |> Enum.map(& &1.id)
      |> MapSet.new()

    invalid_refs =
      changeset
      |> get_field(:connections, [])
      |> Enum.reduce([], fn connection, errors ->
        errors
        |> maybe_add_missing_step_ref(
          MapSet.member?(step_ids, connection.source_step_id),
          connection.id,
          :source_step_id,
          connection.source_step_id
        )
        |> maybe_add_missing_step_ref(
          MapSet.member?(step_ids, connection.target_step_id),
          connection.id,
          :target_step_id,
          connection.target_step_id
        )
      end)
      |> Enum.reverse()

    case invalid_refs do
      [] ->
        changeset

      refs ->
        add_error(
          changeset,
          :connections,
          "references unknown steps: #{Enum.join(refs, ", ")}"
        )
    end
  end

  defp validate_step_group_refs(changeset) do
    step_ids =
      changeset
      |> get_field(:steps, [])
      |> Enum.map(& &1.id)
      |> MapSet.new()

    invalid_refs =
      changeset
      |> get_field(:step_groups, [])
      |> Enum.reduce([], fn step_group, errors ->
        Enum.reduce(step_group.step_ids, errors, fn step_id, acc ->
          if MapSet.member?(step_ids, step_id) do
            acc
          else
            ["#{step_group.id}:#{step_id}" | acc]
          end
        end)
      end)
      |> Enum.reverse()

    case invalid_refs do
      [] ->
        changeset

      refs ->
        add_error(
          changeset,
          :step_groups,
          "reference unknown steps: #{Enum.join(refs, ", ")}"
        )
    end
  end

  defp validate_non_overlapping_step_groups(changeset) do
    overlapping_refs =
      changeset
      |> get_field(:step_groups, [])
      |> Enum.reduce(%{}, fn step_group, memberships ->
        Enum.reduce(step_group.step_ids, memberships, fn step_id, acc ->
          Map.update(acc, step_id, [step_group.id], &[step_group.id | &1])
        end)
      end)
      |> Enum.reduce([], fn {step_id, group_ids}, overlaps ->
        unique_group_ids = group_ids |> Enum.uniq() |> Enum.sort()

        if length(unique_group_ids) > 1 do
          ["#{step_id} in groups #{Enum.join(unique_group_ids, ", ")}" | overlaps]
        else
          overlaps
        end
      end)
      |> Enum.reverse()

    case overlapping_refs do
      [] ->
        changeset

      overlaps ->
        add_error(
          changeset,
          :step_groups,
          "contain overlapping step memberships: #{Enum.join(overlaps, "; ")}"
        )
    end
  end

  defp validate_acyclic_graph(changeset) do
    steps = get_field(changeset, :steps, [])
    connections = get_field(changeset, :connections, [])

    case Graph.from_workflow(steps, connections) do
      {:ok, graph} ->
        case Graph.topological_sort(graph) do
          {:ok, _sorted_step_ids} ->
            changeset

          {:error, {:cycle_detected, step_ids}} ->
            add_error(
              changeset,
              :connections,
              "creates a cycle involving steps: #{Enum.join(Enum.sort(step_ids), ", ")}"
            )
        end

      {:error, {:invalid_edges, invalid_edges}} ->
        add_error(
          changeset,
          :connections,
          "contain invalid edges: #{format_invalid_edges(invalid_edges)}"
        )
    end
  end

  defp validate_step_configs(changeset) do
    changeset
    |> get_field(:steps, [])
    |> PublishValidation.step_config_issues()
    |> Enum.reduce(changeset, fn issue, acc ->
      add_error(
        acc,
        :steps,
        "step #{issue.step_id} has invalid config: #{PublishValidation.format_step_config_issue(issue)}"
      )
    end)
  end

  defp validate_has_entry_step(changeset) do
    steps = get_field(changeset, :steps, [])
    connections = get_field(changeset, :connections, [])

    case PublishValidation.has_entry_step_issues(steps, connections) do
      [] ->
        changeset

      [_issue | _rest] ->
        add_error(changeset, :steps, PublishValidation.has_entry_step_message())
    end
  end

  defp validate_expression_integrity(changeset) do
    changeset
    |> get_field(:steps, [])
    |> PublishValidation.expression_issues()
    |> Enum.reduce(changeset, fn issue, acc ->
      add_error(
        acc,
        :steps,
        "step #{issue.step_id} #{PublishValidation.format_expression_issue(issue)}"
      )
    end)
  end

  defp validate_credential_declarations(changeset) do
    changeset
    |> get_field(:steps, [])
    |> PublishValidation.credential_declaration_issues()
    |> Enum.reduce(changeset, fn issue, acc ->
      add_error(
        acc,
        :steps,
        "step #{issue.step_id} has invalid credential declaration: #{PublishValidation.format_expression_issue(issue)}"
      )
    end)
  end

  defp maybe_add_missing_step_ref(errors, true, _connection_id, _field, _step_id), do: errors

  defp maybe_add_missing_step_ref(errors, false, connection_id, field, step_id) do
    ["#{connection_id} #{field}=#{step_id}" | errors]
  end

  defp duplicate_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.reduce([], fn {value, count}, duplicates ->
      if count > 1 do
        [value | duplicates]
      else
        duplicates
      end
    end)
    |> Enum.sort()
  end

  defp format_invalid_edges(invalid_edges) do
    invalid_edges
    |> Enum.map(fn {source_step_id, target_step_id} -> "#{source_step_id}->#{target_step_id}" end)
    |> Enum.join(", ")
  end
end
