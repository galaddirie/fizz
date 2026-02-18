defmodule Fizz.Repo.Migrations.AddUserScopedUniqueDisplayLabelToApiCredentials do
  use Ecto.Migration

  def change do
    create unique_index(:api_credentials, [:workos_organization_id, :user_id, :provider_label],
             name: :api_credentials_org_user_provider_label_index
           )
  end
end
