defmodule Fizz.External.WorkOSSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :external_api
  @moduletag skip: System.get_env("WORKOS_SMOKE_USER_ID") in [nil, ""]

  test "lists organization memberships for a real WorkOS user" do
    workos_user_id = System.fetch_env!("WORKOS_SMOKE_USER_ID")

    assert {:ok, memberships} =
             Fizz.Accounts.WorkOS.list_user_organization_memberships(workos_user_id)

    assert is_list(memberships)
  end
end
