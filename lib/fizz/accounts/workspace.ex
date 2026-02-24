defmodule Fizz.Accounts.Workspace do
  @moduledoc """
  A generic organizational unit for grouping related resources and work within
  a WorkOS organization.

  More focused than an organization, more generic than a "project". In a B2B
  SaaS context a client typically maps to one workspace, or to multiple
  workspaces for larger clients.

  Each workspace is scoped to a WorkOS organization via `workos_organization_id`.
  Slugs are unique per organization and auto-generated from the name if not
  provided. Access is controlled through `Fizz.Accounts.WorkspaceMembership`.
  """

  use Fizz.Schema

  alias Fizz.Accounts.WorkspaceMembership

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :description,
             :metadata,
             :workos_organization_id,
             :inserted_at,
             :updated_at
           ]}
  @derive {LiveVue.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :description,
             :metadata,
             :workos_organization_id,
             :inserted_at,
             :updated_at
           ]}

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :metadata, :map, default: %{}
    field :workos_organization_id, :string

    has_many :memberships, WorkspaceMembership

    timestamps()
  end

  @doc false
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :slug, :description, :metadata, :workos_organization_id])
    |> validate_required([:name, :slug, :workos_organization_id])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:description, max: 280)
    |> validate_slug()
    |> validate_length(:workos_organization_id, min: 3, max: 120)
    |> unique_constraint(:slug, name: :workspaces_workos_organization_id_slug_index)
  end

  defp validate_slug(changeset) do
    changeset
    |> update_change(:slug, &String.downcase/1)
    |> validate_length(:slug, min: 2, max: 80)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must contain lowercase letters, numbers, and hyphens only"
    )
  end
end
