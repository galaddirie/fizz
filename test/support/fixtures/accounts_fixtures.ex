defmodule Fizz.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Fizz.Accounts` context.
  """

  alias Fizz.Accounts
  alias Fizz.Accounts.{Scope, User}

  def unique_user_email, do: "user-#{unique_suffix()}@example.com"

  def unique_workos_user_id, do: "user_workos_#{unique_suffix()}"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      workos_user_id: unique_workos_user_id(),
      confirmed_at: DateTime.utc_now(:second)
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> valid_user_attributes()
      |> Map.put(:confirmed_at, nil)

    {:ok, user} =
      %User{}
      |> User.workos_profile_changeset(attrs)
      |> Fizz.Repo.insert()

    user
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      %User{}
      |> User.workos_profile_changeset(valid_user_attributes(attrs))
      |> Fizz.Repo.insert()

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def organization_scope_fixture(opts \\ []) do
    user = Keyword.get(opts, :user, user_fixture())

    organization_id =
      Keyword.get(opts, :organization_id, "org_#{System.unique_integer([:positive])}")

    organization_role = Keyword.get(opts, :organization_role, :owner)

    Scope.for_user(user)
    |> Scope.with_organization_id(organization_id)
    |> Scope.with_organization_role(organization_role)
  end

  def project_fixture(scope, attrs \\ %{}) do
    {:ok, project} =
      Accounts.create_project(
        scope,
        Map.merge(%{name: "Project #{unique_suffix()}"}, attrs)
      )

    project
  end

  defp unique_suffix do
    Ecto.UUID.generate()
  end
end
