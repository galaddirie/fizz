defmodule Fizz.Repo.Migrations.DropIsolationLevelsFromTenantsAndWorkspaces do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      remove :isolation_level, :string
    end

    alter table(:workspaces) do
      remove :isolation_level, :string
    end
  end
end
