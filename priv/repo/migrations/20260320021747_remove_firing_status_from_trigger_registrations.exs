defmodule Fizz.Repo.Migrations.RemoveFiringStatusFromTriggerRegistrations do
  use Ecto.Migration

  def up do
    execute "UPDATE trigger_registrations SET status = 'active' WHERE status = 'firing'"

    execute """
    ALTER TABLE trigger_registrations
      DROP CONSTRAINT trigger_registrations_status_check,
      ADD CONSTRAINT trigger_registrations_status_check
        CHECK (status IN ('active', 'paused', 'errored', 'inactive'))
    """
  end

  def down do
    execute """
    ALTER TABLE trigger_registrations
      DROP CONSTRAINT trigger_registrations_status_check,
      ADD CONSTRAINT trigger_registrations_status_check
        CHECK (status IN ('active', 'paused', 'errored', 'inactive', 'firing'))
    """
  end
end
