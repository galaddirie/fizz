defmodule Fizz.Integrations.IntegrationCredential do
  @moduledoc """
  Organization-scoped metadata for provider credentials stored in WorkOS Vault.

  This schema stores only metadata and Vault references. Secret values never
  persist in the local database.
  """

  use Fizz.Schema

  alias Fizz.Accounts.User
  alias Fizz.Integrations.IntegrationConnection

  @type t :: %__MODULE__{}

  schema "integration_credentials" do
    field :workos_organization_id, :string
    field :provider, :string
    field :provider_label, :string
    field :provider_custom_name, :string
    field :vault_object_id, :string
    field :vault_object_name, :string
    field :vault_version, :string
    field :last_used_at, :utc_datetime_usec

    belongs_to :user, User
    has_many :integration_connections, IntegrationConnection, foreign_key: :credential_id

    timestamps()
  end

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :user_id,
      :workos_organization_id,
      :provider,
      :provider_label,
      :provider_custom_name,
      :vault_object_id,
      :vault_object_name,
      :vault_version,
      :last_used_at
    ])
    |> validate_required([
      :user_id,
      :workos_organization_id,
      :provider,
      :provider_label,
      :vault_object_id,
      :vault_object_name
    ])
    |> validate_length(:provider, min: 2, max: 64)
    |> validate_length(:provider_label, min: 2, max: 80)
    |> validate_length(:provider_custom_name, max: 120)
    |> validate_length(:workos_organization_id, min: 3, max: 120)
    |> validate_length(:vault_object_id, min: 3, max: 255)
    |> validate_length(:vault_object_name, min: 3, max: 255)
    |> validate_provider_custom_name()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:workos_organization_id, :user_id, :provider],
      name: :integration_credentials_org_user_provider_index
    )
    |> unique_constraint(:vault_object_id)
    |> unique_constraint(:vault_object_name)
  end

  defp validate_provider_custom_name(changeset) do
    provider = get_field(changeset, :provider)
    custom_name = get_field(changeset, :provider_custom_name)

    if provider == "custom" do
      if is_binary(custom_name) and byte_size(String.trim(custom_name)) > 0 do
        changeset
      else
        add_error(changeset, :provider_custom_name, "is required for custom providers")
      end
    else
      changeset
    end
  end
end
