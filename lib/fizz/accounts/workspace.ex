defmodule Fizz.Accounts.Workspace do
  use Fizz.Schema

  alias Fizz.Accounts.{Organization, WorkspaceMembership}

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    has_many :memberships, WorkspaceMembership

    timestamps()
  end

  @doc false
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :slug, :description, :metadata])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:description, max: 280)
    |> validate_slug()
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint(:slug, name: :workspaces_organization_id_slug_index)
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
