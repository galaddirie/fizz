defmodule Fizz.Workflows.SignalInbox do
  @moduledoc """
  Durable inbox for external signals targeting workflow runs.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Project
  alias Fizz.Workflows.WorkflowRun

  @statuses ~w(pending delivered skipped)a

  schema "signal_inbox" do
    field :signal_id, :string
    field :signal_name, :string
    field :payload, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :workos_organization_id, :string
    field :delivered_at, :utc_datetime_usec

    belongs_to :run, WorkflowRun
    belongs_to :project, Project

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(signal, attrs) do
    signal
    |> cast(attrs, [
      :run_id,
      :signal_id,
      :signal_name,
      :payload,
      :status,
      :project_id,
      :workos_organization_id,
      :delivered_at
    ])
    |> validate_required([
      :run_id,
      :signal_id,
      :signal_name,
      :payload,
      :status,
      :project_id,
      :workos_organization_id
    ])
    |> validate_length(:signal_id, min: 1, max: 255)
    |> validate_length(:signal_name, min: 1, max: 255)
    |> validate_length(:workos_organization_id, min: 3, max: 255)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:run_id, :signal_id])
    |> check_constraint(:status, name: :signal_inbox_status_check)
  end
end
