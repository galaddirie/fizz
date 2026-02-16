defmodule Fizz.Sprites.WorkspaceSpriteLimit do
  @moduledoc """
  Per-workspace quota and throttling configuration for Sprites operations.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Workspace

  schema "workspace_sprite_limits" do
    field :max_sprites, :integer, default: 20
    field :max_concurrent_jobs, :integer, default: 5
    field :max_jobs_per_minute, :integer, default: 30
    field :max_console_sessions, :integer, default: 2
    field :max_services_per_sprite, :integer, default: 10
    field :max_checkpoints_per_sprite, :integer, default: 50
    field :daily_exec_seconds_limit, :integer, default: 36_000
    field :daily_log_bytes_limit, :integer, default: 2_147_483_648

    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc false
  def changeset(limit, attrs) do
    limit
    |> cast(attrs, [
      :workspace_id,
      :max_sprites,
      :max_concurrent_jobs,
      :max_jobs_per_minute,
      :max_console_sessions,
      :max_services_per_sprite,
      :max_checkpoints_per_sprite,
      :daily_exec_seconds_limit,
      :daily_log_bytes_limit
    ])
    |> validate_required([:workspace_id])
    |> validate_number(:max_sprites, greater_than: 0)
    |> validate_number(:max_concurrent_jobs, greater_than: 0)
    |> validate_number(:max_jobs_per_minute, greater_than: 0)
    |> validate_number(:max_console_sessions, greater_than: 0)
    |> validate_number(:max_services_per_sprite, greater_than: 0)
    |> validate_number(:max_checkpoints_per_sprite, greater_than: 0)
    |> validate_number(:daily_exec_seconds_limit, greater_than: 0)
    |> validate_number(:daily_log_bytes_limit, greater_than: 0)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:workspace_id)
  end
end
