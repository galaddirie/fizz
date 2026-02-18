defmodule Fizz.Accounts.OauthConnection do
  @moduledoc """
  Organization-scoped index of a user's provider auth state.

  This table stores metadata only (status, scopes, provider profile data, and
  references). Secrets and OAuth tokens are never persisted locally.
  """

  use Fizz.Schema

  alias Fizz.Accounts.User

  @statuses [:active, :inactive, :needs_reauthorization, :error]

  @type t :: %__MODULE__{}

  schema "oauth_connections" do
    field :workos_organization_id, :string
    field :provider, :string
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :scopes, {:array, :string}, default: []
    field :missing_scopes, {:array, :string}, default: []
    field :provider_metadata, :map, default: %{}
    field :last_token_fetch_at, :utc_datetime_usec
    field :last_error, :string
    field :disconnected_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :workos_organization_id,
      :user_id,
      :provider,
      :status,
      :scopes,
      :missing_scopes,
      :provider_metadata,
      :last_token_fetch_at,
      :last_error,
      :disconnected_at
    ])
    |> validate_required([:workos_organization_id, :user_id, :provider, :status])
    |> validate_length(:provider, min: 2, max: 64)
    |> validate_length(:workos_organization_id, min: 3, max: 120)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:workos_organization_id, :user_id, :provider],
      name: :oauth_connections_org_user_provider_index
    )
  end
end
