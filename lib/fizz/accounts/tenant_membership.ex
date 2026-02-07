defmodule Fizz.Accounts.TenantMembership do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fizz.Accounts.{Tenant, User}

  @roles [:owner, :admin, :member]

  schema "tenant_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :member
    field :workos_organization_membership_id, :string

    belongs_to :tenant, Tenant
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :workos_organization_membership_id])
    |> validate_required([:role])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id, name: :tenant_memberships_tenant_id_user_id_index)
    |> unique_constraint(:workos_organization_membership_id)
  end
end
