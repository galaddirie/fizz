defmodule Fizz.Triggers.TriggerSource do
  @moduledoc """
  Durable external trigger source shared by one or more workflow registrations.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Project
  alias Fizz.Triggers.{TriggerRegistration, TriggerSourceRow}

  @type t :: %__MODULE__{}

  @kinds ~w(polling subscription)
  @statuses ~w(active paused errored inactive)

  schema "trigger_sources" do
    field :workos_organization_id, :string
    field :user_id, :string
    field :kind, :string
    field :provider, :string
    field :source_module, :string
    field :source_key, :string
    field :status, :string, default: "active"
    field :params, :map, default: %{}
    field :cursor, :map
    field :poll_interval_ms, :integer, default: 60_000
    field :next_poll_at, :utc_datetime_usec
    field :last_polled_at, :utc_datetime_usec
    field :backoff_until, :utc_datetime_usec
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime_usec
    field :error_message, :string
    field :consecutive_errors, :integer, default: 0
    field :last_error_at, :utc_datetime_usec

    belongs_to :project, Project
    has_many :registrations, TriggerRegistration
    has_many :rows, TriggerSourceRow

    timestamps()
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :project_id,
      :workos_organization_id,
      :user_id,
      :kind,
      :provider,
      :source_module,
      :source_key,
      :status,
      :params,
      :cursor,
      :poll_interval_ms,
      :next_poll_at,
      :last_polled_at,
      :backoff_until,
      :lease_owner,
      :lease_expires_at,
      :error_message,
      :consecutive_errors,
      :last_error_at
    ])
    |> validate_required([
      :project_id,
      :workos_organization_id,
      :user_id,
      :kind,
      :provider,
      :source_module,
      :source_key,
      :status,
      :params
    ])
    |> validate_length(:workos_organization_id, min: 3, max: 255)
    |> validate_length(:user_id, min: 1, max: 255)
    |> validate_length(:provider, min: 1, max: 255)
    |> validate_length(:source_module, min: 1, max: 512)
    |> validate_length(:source_key, min: 1, max: 512)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:poll_interval_ms, greater_than: 0)
    |> validate_number(:consecutive_errors, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:source_key, name: :trigger_sources_source_key_index)
    |> check_constraint(:kind, name: :trigger_sources_kind_check)
    |> check_constraint(:status, name: :trigger_sources_status_check)
  end
end
