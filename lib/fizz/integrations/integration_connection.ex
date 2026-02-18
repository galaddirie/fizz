defmodule Fizz.Integrations.IntegrationConnection do
  @moduledoc """
  Tracks the state of a user's connection to an external provider (GitHub, GitLab, etc.)
  within a workspace. No tokens are stored — they are fetched live from WorkOS Pipes.
  """

  use Fizz.Schema

  alias Fizz.Accounts.{User, Workspace}
  alias Fizz.Integrations.IntegrationCredential

  @statuses [:active, :inactive, :needs_reauthorization, :error]
  @auth_methods [:oauth, :api_key]

  @type t :: %__MODULE__{}

  schema "integration_connections" do
    field :provider, :string
    field :auth_method, Ecto.Enum, values: @auth_methods, default: :oauth
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :scopes, {:array, :string}, default: []
    field :missing_scopes, {:array, :string}, default: []
    field :provider_metadata, :map, default: %{}
    field :last_token_fetch_at, :utc_datetime_usec
    field :last_error, :string
    field :disconnected_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :user, User
    belongs_to :credential, IntegrationCredential

    timestamps()
  end

  @doc false
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :workspace_id,
      :user_id,
      :provider,
      :auth_method,
      :credential_id,
      :status,
      :scopes,
      :missing_scopes,
      :provider_metadata,
      :last_token_fetch_at,
      :last_error,
      :disconnected_at
    ])
    |> validate_required([:workspace_id, :user_id, :provider, :auth_method, :status])
    |> validate_length(:provider, min: 2, max: 64)
    |> validate_auth_method_credential()
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:credential_id)
    |> check_constraint(:credential_id,
      name: :integration_connections_auth_method_credential_check
    )
    |> unique_constraint([:workspace_id, :user_id, :provider])
  end

  defp validate_auth_method_credential(changeset) do
    auth_method = get_field(changeset, :auth_method)
    credential_id = get_field(changeset, :credential_id)

    cond do
      auth_method == :oauth and is_nil(credential_id) ->
        changeset

      auth_method == :api_key and is_binary(credential_id) ->
        changeset

      auth_method == :oauth ->
        add_error(changeset, :credential_id, "must be empty when auth method is oauth")

      auth_method == :api_key ->
        add_error(changeset, :credential_id, "is required when auth method is api_key")

      true ->
        changeset
    end
  end
end
