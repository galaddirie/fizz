defmodule Fizz.Accounts.User do
  @moduledoc """
  A user authenticated via WorkOS AuthKit — no local passwords are stored.

  The local record holds `email` and `workos_user_id` for linking to the
  external WorkOS identity. `confirmed_at` tracks email verification status
  (set when WorkOS reports the email as verified). `authenticated_at` is a
  virtual field populated at login time and is not persisted.
  """

  use Fizz.Schema

  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :workos_user_id, :string

    has_many :project_memberships, Fizz.Accounts.ProjectMembership

    timestamps()
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
