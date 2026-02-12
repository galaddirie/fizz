defmodule FizzWeb.ProfileLiveTest do
  use FizzWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Fizz.AccountsFixtures

  defmodule ReqMock do
    def request(opts) do
      owner = :persistent_term.get({FizzWeb.ProfileLiveTest, :owner}, nil)
      mock_store = :persistent_term.get({FizzWeb.ProfileLiveTest, :mock_store}, nil)

      if owner do
        send(owner, {:workos_http_request, opts})
      end

      if is_pid(mock_store) do
        Agent.get_and_update(mock_store, fn
          [response | rest] -> {response, rest}
          [] -> {:no_mocked_response, []}
        end)
        |> case do
          :no_mocked_response -> raise "No mocked WorkOS HTTP responses were configured"
          response -> response
        end
      else
        raise "No WorkOS mock store configured"
      end
    end
  end

  setup do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)
    mock_store = start_supervised!({Agent, fn -> [] end})

    :persistent_term.put({__MODULE__, :owner}, self())
    :persistent_term.put({__MODULE__, :mock_store}, mock_store)

    Application.put_env(:fizz, :workos_http_client_module, ReqMock)

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
      :persistent_term.erase({__MODULE__, :owner})
      :persistent_term.erase({__MODULE__, :mock_store})
    end)

    :ok
  end

  describe "authenticated profile page" do
    setup :register_and_log_in_user

    test "renders user identifiers and pipes widget", %{conn: conn, user: user} do
      _organization = organization_fixture(user, %{workos_organization_id: "org_123"})

      put_http_responses([
        {:ok, %Req.Response{status: 200, body: %{"token" => "widget_token_123"}}},
        {:ok, %Req.Response{status: 200, body: %{"token" => "widget_token_123"}}}
      ])

      {:ok, view, _html} = live(conn, ~p"/settings/profile")

      assert has_element?(view, "#profile-page")
      assert has_element?(view, "#profile-local-user-id")
      assert has_element?(view, "#profile-workos-user-id")
      assert has_element?(view, "#profile-workos-organization-id")

      assert has_element?(
               view,
               "#profile-pipes-widget-org_123[data-auth-token=\"widget_token_123\"]"
             )

      assert_receive {:workos_http_request, first_request}
      assert first_request[:method] == :post
      assert first_request[:url] == "/widgets/token"

      assert first_request[:json] == %{
               organization_id: "org_123",
               scopes: [],
               user_id: user.workos_user_id
             }

      assert_receive {:workos_http_request, second_request}
      assert second_request[:method] == :post
      assert second_request[:url] == "/widgets/token"

      assert second_request[:json] == %{
               organization_id: "org_123",
               scopes: [],
               user_id: user.workos_user_id
             }
    end

    test "switches organizations and refreshes widget token", %{conn: conn, user: user} do
      _organization1 =
        organization_fixture(user, %{name: "Alpha", workos_organization_id: "org_123"})

      _organization2 =
        organization_fixture(user, %{name: "Beta", workos_organization_id: "org_456"})

      put_http_responses([
        {:ok, %Req.Response{status: 200, body: %{"token" => "widget_token_123"}}},
        {:ok, %Req.Response{status: 200, body: %{"token" => "widget_token_123"}}},
        {:ok, %Req.Response{status: 200, body: %{"token" => "widget_token_456"}}}
      ])

      {:ok, view, _html} = live(conn, ~p"/settings/profile")

      assert has_element?(
               view,
               "#profile-pipes-widget-org_123[data-auth-token=\"widget_token_123\"]"
             )

      view
      |> element("#profile-organization-form")
      |> render_change(%{"organization" => %{"organization_id" => "org_456"}})

      assert has_element?(
               view,
               "#profile-pipes-widget-org_456[data-auth-token=\"widget_token_456\"]"
             )

      assert_receive {:workos_http_request, first_request}
      assert first_request[:url] == "/widgets/token"

      assert first_request[:json] == %{
               organization_id: "org_123",
               scopes: [],
               user_id: user.workos_user_id
             }

      assert_receive {:workos_http_request, second_request}
      assert second_request[:url] == "/widgets/token"

      assert second_request[:json] == %{
               organization_id: "org_123",
               scopes: [],
               user_id: user.workos_user_id
             }

      assert_receive {:workos_http_request, third_request}
      assert third_request[:url] == "/widgets/token"

      assert third_request[:json] == %{
               organization_id: "org_456",
               scopes: [],
               user_id: user.workos_user_id
             }
    end

    test "uses WorkOS memberships when local organization mapping is missing", %{
      conn: conn,
      user: user
    } do
      put_http_responses([
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "data" => [
               %{"id" => "om_123", "organization_id" => "org_789", "status" => "active"}
             ]
           }
         }},
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "data" => [
               %{"id" => "om_123", "organization_id" => "org_789", "status" => "active"}
             ]
           }
         }},
        {:ok, %Req.Response{status: 200, body: %{"token" => "widget_token_789"}}},
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "data" => [
               %{"id" => "om_123", "organization_id" => "org_789", "status" => "active"}
             ]
           }
         }},
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "data" => [
               %{"id" => "om_123", "organization_id" => "org_789", "status" => "active"}
             ]
           }
         }},
        {:ok, %Req.Response{status: 200, body: %{"token" => "widget_token_789"}}}
      ])

      {:ok, view, _html} = live(conn, ~p"/settings/profile")

      assert has_element?(
               view,
               "#profile-pipes-widget-org_789[data-auth-token=\"widget_token_789\"]"
             )

      refute has_element?(view, "#profile-no-organization")

      assert_receive {:workos_http_request, first_request}
      assert first_request[:method] == :get
      assert first_request[:url] == "/user_management/organization_memberships"
      refute Enum.any?(first_request[:params], fn {key, _value} -> key == :organization_id end)

      assert_receive {:workos_http_request, second_request}
      assert second_request[:method] == :get
      assert second_request[:url] == "/user_management/organization_memberships"

      assert Enum.any?(second_request[:params], fn {key, value} ->
               key == :organization_id and value == "org_789"
             end)

      assert_receive {:workos_http_request, third_request}
      assert third_request[:method] == :post
      assert third_request[:url] == "/widgets/token"

      assert third_request[:json] == %{
               organization_id: "org_789",
               scopes: [],
               user_id: user.workos_user_id
             }
    end

    test "shows a single no-organization state when no WorkOS organization is linked", %{
      conn: conn
    } do
      put_http_responses([
        {:ok, %Req.Response{status: 200, body: %{"data" => []}}},
        {:ok, %Req.Response{status: 200, body: %{"data" => []}}}
      ])

      {:ok, view, _html} = live(conn, ~p"/settings/profile")

      assert has_element?(view, "#profile-no-organization")
      refute has_element?(view, "#profile-pipes-widget-error")
      refute has_element?(view, "[id^='profile-pipes-widget-org_']")

      assert_receive {:workos_http_request, first_request}
      assert first_request[:method] == :get
      assert first_request[:url] == "/user_management/organization_memberships"

      assert_receive {:workos_http_request, second_request}
      assert second_request[:method] == :get
      assert second_request[:url] == "/user_management/organization_memberships"
    end
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/workos"}}} = live(conn, ~p"/settings/profile")
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp put_http_responses(responses) do
    mock_store = :persistent_term.get({__MODULE__, :mock_store})
    Agent.update(mock_store, fn _ -> responses end)
  end
end
