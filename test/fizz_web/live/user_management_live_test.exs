defmodule FizzWeb.UserManagementLiveTest do
  use FizzWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous_workos_client_module = Application.get_env(:fizz, :workos_client_module)
    mock_store = start_supervised!({Agent, fn -> %{} end})

    Fizz.WorkOSClientMock.configure(self(), mock_store)
    Application.put_env(:fizz, :workos_client_module, Fizz.WorkOSClientMock)

    on_exit(fn ->
      restore_env(:fizz, :workos_client_module, previous_workos_client_module)
      Fizz.WorkOSClientMock.reset()
    end)

    :ok
  end

  describe "authenticated users management page" do
    setup :register_and_log_in_user

    test "renders all management widget mounts", %{conn: conn} do
      organization_memberships = [
        %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
      ]

      Fizz.WorkOSClientMock.put_responses(%{
        list_user_organization_memberships: List.duplicate({:ok, organization_memberships}, 8),
        user_has_organization_membership?: List.duplicate({:ok, true}, 8),
        generate_widget_token: List.duplicate({:ok, "widget_token_123"}, 8)
      })

      {:ok, view, _html} = live(conn, ~p"/settings/")

      assert has_element?(view, "#user-management-page")
      assert has_element?(view, "#user-management-context")
      assert has_element?(view, "#user-management-organization-form")

      assert has_element?(
               view,
               "#user-management-users-management-widget-org_123[data-widget=\"users-management\"][data-auth-token=\"widget_token_123\"]"
             )

      assert has_element?(
               view,
               "#user-management-organization-switcher-widget-org_123[data-widget=\"organization-switcher\"][data-auth-token=\"widget_token_123\"]"
             )

      assert has_element?(
               view,
               "#user-management-user-profile-widget-org_123[data-widget=\"user-profile\"][data-auth-token=\"widget_token_123\"]"
             )

      assert has_element?(
               view,
               "#user-management-user-security-widget-org_123[data-widget=\"user-security\"][data-auth-token=\"widget_token_123\"]"
             )

      assert has_element?(
               view,
               "#user-management-api-keys-widget-org_123[data-widget=\"api-keys\"][data-auth-token=\"widget_token_123\"]"
             )
    end

    test "switches organizations and refreshes token", %{conn: conn} do
      organization_memberships = [
        %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"},
        %{"id" => "om_2", "organization_id" => "org_456", "status" => "active"}
      ]

      Fizz.WorkOSClientMock.put_responses(%{
        list_user_organization_memberships: List.duplicate({:ok, organization_memberships}, 8),
        user_has_organization_membership?: List.duplicate({:ok, true}, 8),
        generate_widget_token: [
          {:ok, "widget_token_123"},
          {:ok, "widget_token_123"},
          {:ok, "widget_token_456"},
          {:ok, "widget_token_456"}
        ]
      })

      {:ok, view, _html} = live(conn, ~p"/settings/")

      assert has_element?(
               view,
               "#user-management-users-management-widget-org_123[data-auth-token=\"widget_token_123\"]"
             )

      view
      |> element("#user-management-organization-form")
      |> render_change(%{"organization" => %{"organization_id" => "org_456"}})

      assert has_element?(
               view,
               "#user-management-users-management-widget-org_456[data-auth-token=\"widget_token_456\"]"
             )
    end

    test "shows a single no-organization state when no WorkOS organization is linked", %{
      conn: conn
    } do
      Fizz.WorkOSClientMock.put_responses(%{
        list_user_organization_memberships: List.duplicate({:ok, []}, 4)
      })

      {:ok, view, _html} = live(conn, ~p"/settings/")

      assert has_element?(view, "#user-management-no-organization")
      refute has_element?(view, "#user-management-widget-error")
      refute has_element?(view, "[id^='user-management-users-management-widget-org_']")
    end
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/settings/")
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
