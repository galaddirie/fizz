defmodule Fizz.Sprites.WorkspaceUsageDaily do
  @moduledoc """
  Aggregated daily usage metrics per workspace.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Workspace

  schema "workspace_usage_daily" do
    field :usage_date, :date
    field :jobs_total, :integer, default: 0
    field :jobs_succeeded, :integer, default: 0
    field :jobs_failed, :integer, default: 0
    field :jobs_canceled, :integer, default: 0
    field :exec_seconds, :integer, default: 0
    field :log_bytes, :integer, default: 0
    field :console_seconds, :integer, default: 0
    field :sprites_created, :integer, default: 0
    field :sprites_deleted, :integer, default: 0
    field :quota_rejections, :integer, default: 0
    field :rate_limited, :integer, default: 0

    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc false
  def changeset(usage, attrs) do
    usage
    |> cast(attrs, [
      :workspace_id,
      :usage_date,
      :jobs_total,
      :jobs_succeeded,
      :jobs_failed,
      :jobs_canceled,
      :exec_seconds,
      :log_bytes,
      :console_seconds,
      :sprites_created,
      :sprites_deleted,
      :quota_rejections,
      :rate_limited
    ])
    |> validate_required([:workspace_id, :usage_date])
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:usage_date, name: :workspace_usage_daily_workspace_id_usage_date_index)
  end
end
