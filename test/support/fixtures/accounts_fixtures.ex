defmodule Fizz.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Fizz.Accounts` context.
  """

  import Ecto.Query

  alias Fizz.Accounts
  alias Fizz.Accounts.{Scope, User}

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"

  def unique_workos_user_id, do: "user_workos_#{System.unique_integer([:positive])}"

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

  def tenant_fixture(user \\ user_fixture(), attrs \\ %{}) do
    scope = Scope.for_user(user)

    {:ok, tenant} =
      Accounts.create_tenant(
        scope,
        Map.merge(%{name: "Tenant #{System.unique_integer()}"}, attrs),
        sync_workos: false
      )

    tenant
  end

  def tenant_scope_fixture(opts \\ []) do
    user = user_fixture()
    tenant = tenant_fixture(user)
    tenant_scope_fixture(user, tenant, opts)
  end

  def tenant_scope_fixture(user, tenant, opts \\ []) do
    {:ok, scope} = Accounts.build_scope(Scope.for_user(user), tenant.id, opts)
    scope
  end

  def workspace_fixture(scope, attrs \\ %{}) do
    {:ok, workspace} =
      Accounts.create_workspace(
        scope,
        Map.merge(%{name: "Workspace #{System.unique_integer()}"}, attrs)
      )

    workspace
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Fizz.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Fizz.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
