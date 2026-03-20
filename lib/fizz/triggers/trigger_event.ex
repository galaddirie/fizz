defmodule Fizz.Triggers.TriggerEvent do
  @moduledoc """
  Durable trigger event log used for deduplication and auditability.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Project
  alias Fizz.Triggers.TriggerRegistration

  @timestamps_opts [inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec]

  @statuses ~w(pending processing fired skipped failed)

  schema "trigger_events" do
    field :workos_organization_id, :string
    field :event_id, :string
    field :event_data, :map
    field :status, :string, default: "pending"
    field :run_id, :binary_id
    field :processed_at, :utc_datetime_usec

    belongs_to :trigger_registration, TriggerRegistration
    belongs_to :project, Project

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(trigger_event, attrs) do
    trigger_event
    |> cast(attrs, [
      :trigger_registration_id,
      :project_id,
      :workos_organization_id,
      :event_id,
      :event_data,
      :status,
      :run_id,
      :processed_at
    ])
    |> validate_required([
      :trigger_registration_id,
      :project_id,
      :workos_organization_id,
      :event_id,
      :status
    ])
    |> validate_length(:workos_organization_id, min: 3, max: 255)
    |> validate_length(:event_id, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:trigger_registration_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:trigger_registration_id, :event_id],
      name: :trigger_events_registration_event_id_index
    )
    |> check_constraint(:status, name: :trigger_events_status_check)
  end
end
