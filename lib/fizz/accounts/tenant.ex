defmodule Fizz.Accounts.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fizz.Accounts.{TenantMembership, Workspace}

  @isolation_levels [:hard, :firm, :soft]

  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :isolation_level, Ecto.Enum, values: @isolation_levels, default: :hard
    field :metadata, :map, default: %{}
    field :workos_organization_id, :string

    has_many :memberships, TenantMembership
    has_many :workspaces, Workspace

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :slug, :isolation_level, :metadata, :workos_organization_id])
    |> validate_required([:name, :slug, :isolation_level])
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
