defmodule Fizz.Workspaces.Service do
  @moduledoc """
  Service definition persisted per workspace.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Project
  alias Fizz.Workspaces.Workspace

  @states [:stopped, :running, :error]

  schema "workspace_services" do
    field :name, :string
    field :cmd, :string
    field :args, {:array, :string}, default: []
    field :needs, {:array, :string}, default: []
    field :status, Ecto.Enum, values: @states, default: :stopped
    field :published, :boolean, default: false
    field :metadata, :map, default: %{}
    field :last_started_at, :utc_datetime_usec
    field :last_stopped_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :project, Project

    timestamps()
  end

  @doc false
  def changeset(service, attrs) do
    service
    |> cast(attrs, [
      :workspace_id,
      :project_id,
      :name,
      :cmd,
      :args,
      :needs,
      :status,
      :published,
      :metadata,
      :last_started_at,
      :last_stopped_at
    ])
    |> validate_required([:workspace_id, :project_id, :name])
    |> validate_length(:name, min: 2, max: 120)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:name, name: :workspace_services_workspace_id_name_index)
  end
end
