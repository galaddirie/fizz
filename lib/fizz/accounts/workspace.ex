defmodule Fizz.Accounts.Workspace do
  use Fizz.Schema

  alias Fizz.Accounts.WorkspaceMembership

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
