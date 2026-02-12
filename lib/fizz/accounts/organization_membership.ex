defmodule Fizz.Accounts.OrganizationMembership do
  use Fizz.Schema

  alias Fizz.Accounts.{Organization, User}

  @roles [:owner, :admin, :member]

  schema "organization_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :member
    field :workos_organization_membership_id, :string

    belongs_to :organization, Organization
    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :workos_organization_membership_id])
    |> validate_required([:role])
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id, name: :organization_memberships_organization_id_user_id_index)
    |> unique_constraint(:workos_organization_membership_id)
  end
end
