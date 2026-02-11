defmodule Fizz.Accounts.ByoCredential do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fizz.Accounts.{Tenant, User}

  @statuses [:active, :revoked]

  schema "byo_credentials" do
    field :provider, :string
    field :label, :string
    field :vault_object_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :revoked_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :user, User
    belongs_to :tenant, Tenant

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for BYO credential form validation.
  """
  def form_changeset(byo_credential, attrs) do
    byo_credential
    |> cast(attrs, [:provider, :label])
    |> validate_required([:provider, :label])
    |> validate_length(:provider, min: 2, max: 80)
    |> validate_length(:label, min: 2, max: 120)
    |> update_change(:provider, &String.downcase/1)
  end

  @doc """
  Changeset for creating a BYO credential metadata record.
  """
  def create_changeset(byo_credential, attrs) do
    byo_credential
    |> cast(attrs, [:provider, :label, :vault_object_id, :tenant_id, :metadata, :status])
    |> validate_required([:provider, :label, :vault_object_id, :status])
    |> validate_length(:provider, min: 2, max: 80)
    |> validate_length(:label, min: 2, max: 120)
    |> validate_length(:vault_object_id, min: 3, max: 160)
    |> validate_inclusion(:status, @statuses)
    |> update_change(:provider, &String.downcase/1)
    |> unique_constraint(:vault_object_id)
  end

  @doc """
  Changeset for revoking an existing BYO credential.
  """
  def revoke_changeset(byo_credential, revoked_at \\ DateTime.utc_now(:second)) do
    change(byo_credential, %{status: :revoked, revoked_at: revoked_at})
  end
end
