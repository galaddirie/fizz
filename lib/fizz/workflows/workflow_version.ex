defmodule Fizz.Workflows.WorkflowVersion do
  @moduledoc """
  Immutable workflow version snapshot.

  Created each time a workflow is published, preserving the exact
  definition for audit trails and execution reproducibility.
  """
  @derive {Jason.Encoder,
           except: [
             :__meta__,
             :workflow,
             :published_by_user
           ]}
  use Fizz.Schema

  alias Fizz.Workflows.Workflow
  alias Fizz.Workflows.Embeds.{Step, Connection, NodeGroup}
  alias Fizz.Accounts.User

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          version_tag: String.t(),
          source_hash: String.t(),
          steps: [Step.t()],
          connections: [Connection.t()],
          groups: [NodeGroup.t()],
          changelog: String.t() | nil,
          published_at: DateTime.t() | nil,
          published_by: Ecto.UUID.t() | nil,
          workflow_id: Ecto.UUID.t(),
          workflow: Workflow.t() | Ecto.Association.NotLoaded.t(),
          published_by_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t()
        }

  schema "workflow_versions" do
    # Human-friendly version tag can be semver or anything else
    field :version_tag, :string

    # Content hash of steps + connections (SHA-256)
    field :source_hash, :string

    embeds_many :steps, Step, on_replace: :delete
    embeds_many :connections, Connection, on_replace: :delete
    embeds_many :groups, NodeGroup, on_replace: :delete

    field :changelog, :string

    field :published_at, :utc_datetime_usec
    belongs_to :published_by_user, User, foreign_key: :published_by

    belongs_to :workflow, Workflow

    # Immutable - no updates
    timestamps(updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :version_tag,
      :changelog,
      :published_at,
      :published_by,
      :source_hash,
      :workflow_id
    ])
    |> cast_embed(:steps, required: true)
    |> cast_embed(:connections)
    |> cast_embed(:groups)
    |> validate_required([:version_tag, :workflow_id, :source_hash])
    |> unique_constraint([:workflow_id, :version_tag])
  end

  @doc """
  Computes a content hash for the given steps and connections.
  Used to detect changes between versions.
  """
  def compute_source_hash(steps, connections, groups \\ []) do
    content =
      %{
        steps: normalize_for_hash(steps),
        connections: normalize_for_hash(connections),
        groups: normalize_for_hash(groups)
      }
      |> Jason.encode!()

    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp normalize_for_hash(items) when is_list(items) do
    items
    |> Enum.map(fn
      %Step{} = step ->
        # Position is excluded as it doesn't affect behavior
        Map.take(step, [:id, :type_id, :name, :config, :notes])

      %Connection{} = conn ->
        Map.take(conn, [:id, :source_step_id, :source_output, :target_step_id, :target_input])

      %NodeGroup{} = group ->
        Map.take(group, [:id, :name, :step_ids, :output_step_id, :color, :font_size, :collapsed])

      item when is_map(item) ->
        Map.drop(item, [:position, :__struct__, :__meta__])
    end)
    |> Enum.sort_by(fn item ->
      # Stable sort by ID, falling back to type or encoded content
      Map.get(item, :id) || Map.get(item, :type) || Jason.encode!(item)
    end)
  end
end
