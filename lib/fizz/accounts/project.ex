defmodule Fizz.Accounts.Project do
  @moduledoc """
  A generic organizational unit for grouping related resources and work within
  a WorkOS organization.

  In a B2B SaaS context a client typically maps to one project, or to multiple
  projects for larger clients.

  Each project is scoped to a WorkOS organization via `workos_organization_id`.
  Slugs are unique per organization and auto-generated from the name if not
  provided. Access is controlled through `Fizz.Accounts.ProjectMembership`.
  """

  use Fizz.Schema

  alias Fizz.Accounts.ProjectMembership

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

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :metadata, :map, default: %{}
    field :workos_organization_id, :string

    has_many :memberships, ProjectMembership

    timestamps()
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :description, :metadata, :workos_organization_id])
    |> validate_required([:name, :slug, :workos_organization_id])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:description, max: 280)
    |> validate_slug()
    |> validate_length(:workos_organization_id, min: 3, max: 120)
    |> unique_constraint(:slug, name: :projects_workos_organization_id_slug_index)
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
