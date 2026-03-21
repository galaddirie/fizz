defmodule Fizz.Repo.Migrations.AllowMultipleApiCredentialsPerProvider do
  use Ecto.Migration

  def change do
    drop_if_exists index(:api_credentials, [:workos_organization_id, :user_id, :provider],
                     name: :api_credentials_org_user_provider_index
                   )

    create index(:api_credentials, [:workos_organization_id, :user_id, :provider],
             name: :api_credentials_org_user_provider_index
           )
  end
end
