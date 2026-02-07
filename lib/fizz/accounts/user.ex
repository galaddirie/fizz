defmodule Fizz.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :workos_user_id, :string

    has_many :tenant_memberships, Fizz.Accounts.TenantMembership
    has_many :workspace_memberships, Fizz.Accounts.WorkspaceMembership

    timestamps(type: :utc_datetime)
  end

  @doc """
  A user changeset for syncing WorkOS identifiers.
  """
  def workos_changeset(user, attrs) do
    user
    |> cast(attrs, [:workos_user_id])
    |> validate_length(:workos_user_id, min: 3, max: 120)
    |> unique_constraint(:workos_user_id)
  end

  @doc """
  A user changeset for provisioning/syncing from WorkOS AuthKit.
  """
  def workos_profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :workos_user_id, :confirmed_at])
    |> validate_required([:email, :workos_user_id])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> validate_length(:workos_user_id, min: 3, max: 120)
    |> unsafe_validate_unique(:email, Fizz.Repo)
    |> unique_constraint(:email)
    |> unique_constraint(:workos_user_id)
  end
end
