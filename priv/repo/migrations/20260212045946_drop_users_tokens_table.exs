defmodule Fizz.Repo.Migrations.DropUsersTokensTable do
  use Ecto.Migration

  def change do
    drop table(:users_tokens)
  end
end
