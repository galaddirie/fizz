defmodule Fizz.Integrations.IntegrationConnection do
  @moduledoc """
  Tracks the state of a user's connection to an external provider (GitHub, GitLab, etc.)
  within a workspace. No tokens are stored — they are fetched live from WorkOS Pipes.
  """

  use Fizz.Schema

  alias Fizz.Accounts.{User, Workspace}

  @statuses [:active, :inactive, :needs_reauthorization, :error]
  @providers ["github"]

  schema "integration_connections" do
    field :provider, :string
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :scopes, {:array, :string}, default: []
    field :missing_scopes, {:array, :string}, default: []
    field :provider_metadata, :map, default: %{}
    field :last_token_fetch_at, :utc_datetime_usec
    field :last_error, :string
    field :disconnected_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :workspace_id,
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
    |> validate_required([:workspace_id, :user_id, :provider, :status])
    |> validate_inclusion(:provider, @providers)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:workspace_id, :user_id, :provider])
  end
end
