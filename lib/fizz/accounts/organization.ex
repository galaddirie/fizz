defmodule Fizz.Accounts.Organization do
  use Fizz.Schema

  alias Fizz.Accounts.{OrganizationMembership, Workspace}

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :metadata, :map, default: %{}
    field :workos_organization_id, :string

    has_many :memberships, OrganizationMembership
    has_many :workspaces, Workspace

    timestamps()
  end

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :slug, :metadata, :workos_organization_id])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_slug()
    |> unique_constraint(:slug)
    |> unique_constraint(:workos_organization_id)
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
