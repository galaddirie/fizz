defmodule Fizz.Workflows.DurableTimer do
  @moduledoc """
  Durable timer row for workflow-level waits that must survive worker shutdown.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Project
  alias Fizz.Workflows.WorkflowRun

  @statuses ~w(pending firing fired cancelled)a

  schema "durable_timers" do
    field :step_id, :string
    field :timer_name, :string
    field :workos_organization_id, :string
    field :fire_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :payload, :map
    field :claimed_at, :utc_datetime_usec
    field :claimed_by, :string

    belongs_to :run, WorkflowRun
    belongs_to :project, Project

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(timer, attrs) do
    timer
    |> cast(attrs, [
      :run_id,
      :step_id,
      :timer_name,
      :project_id,
      :workos_organization_id,
      :fire_at,
      :status,
      :payload,
      :claimed_at,
      :claimed_by
    ])
    |> validate_required([
      :run_id,
      :step_id,
      :timer_name,
      :project_id,
      :workos_organization_id,
      :fire_at,
      :status
    ])
    |> validate_length(:step_id, min: 1, max: 255)
    |> validate_length(:timer_name, min: 1, max: 255)
    |> validate_length(:workos_organization_id, min: 3, max: 255)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:project_id)
    |> check_constraint(:status, name: :durable_timers_status_check)
  end
end
