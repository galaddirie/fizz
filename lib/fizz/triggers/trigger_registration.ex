defmodule Fizz.Triggers.TriggerRegistration do
  @moduledoc """
  Persistent registration for a workflow trigger source.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Project
  alias Fizz.Workflows.{WorkflowDefinition, WorkflowDefinitionVersion, WorkflowRun}

  @kinds ~w(manual webhook schedule polling subscription chat)
  @statuses ~w(active paused errored inactive)

  schema "trigger_registrations" do
    field :step_id, :string
    field :workos_organization_id, :string
    field :kind, :string
    field :status, :string, default: "active"
    field :registration_params, :map, default: %{}
    field :config_digest, :string
    field :webhook_path, :string
    field :webhook_secret, :string
    field :cron_expression, :string
    field :next_fire_at, :utc_datetime_usec
    field :cursor, :map
    field :poll_interval_ms, :integer
    field :last_polled_at, :utc_datetime_usec
    field :batch_size, :integer, default: 100
    field :error_message, :string
    field :consecutive_errors, :integer, default: 0
    field :last_error_at, :utc_datetime_usec

    belongs_to :workflow_definition, WorkflowDefinition
    belongs_to :definition_version, WorkflowDefinitionVersion
    belongs_to :project, Project
    belongs_to :run, WorkflowRun

    timestamps()
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(registration, attrs) do
    registration
    |> cast(attrs, [
      :workflow_definition_id,
      :definition_version_id,
      :step_id,
      :project_id,
      :workos_organization_id,
      :run_id,
      :kind,
      :status,
      :registration_params,
      :config_digest,
      :webhook_path,
      :webhook_secret,
      :cron_expression,
      :next_fire_at,
      :cursor,
      :poll_interval_ms,
      :last_polled_at,
      :batch_size,
      :error_message,
      :consecutive_errors,
      :last_error_at
    ])
    |> validate_required([
      :workflow_definition_id,
      :definition_version_id,
      :step_id,
      :project_id,
      :workos_organization_id,
      :kind,
      :status,
      :registration_params,
      :config_digest
    ])
    |> validate_length(:step_id, min: 1, max: 255)
    |> validate_length(:workos_organization_id, min: 3, max: 255)
    |> validate_length(:config_digest, min: 1, max: 255)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:batch_size, greater_than: 0)
    |> validate_number(:consecutive_errors, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:workflow_definition_id)
    |> foreign_key_constraint(:definition_version_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:definition_version_id, :step_id],
      name: :trigger_registrations_definition_level_step_index
    )
    |> unique_constraint([:run_id, :step_id], name: :trigger_registrations_run_level_step_index)
    |> unique_constraint(:webhook_path, name: :trigger_registrations_active_webhook_path_index)
    |> check_constraint(:kind, name: :trigger_registrations_kind_check)
    |> check_constraint(:status, name: :trigger_registrations_status_check)
  end
end
