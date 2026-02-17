defmodule Fizz.Repo.Migrations.RemoveSpritesUsageTrackingAndQuotas do
  use Ecto.Migration

  def change do
    drop table(:workspace_rate_limit_windows)
    drop table(:workspace_usage_daily)
    drop table(:workspace_sprite_limits)
  end
end
