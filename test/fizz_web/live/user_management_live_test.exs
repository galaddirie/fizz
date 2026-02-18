defmodule FizzWeb.UserManagementLiveTest do
  use FizzWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fizz.Accounts.ApiCredential
  alias Fizz.Repo

  defmodule ReqMock do
    def request(opts) do
      owner = :persistent_term.get({FizzWeb.UserManagementLiveTest, :owner}, nil)
      mock_store = :persistent_term.get({FizzWeb.UserManagementLiveTest, :mock_store}, nil)

      if owner do
        send(owner, {:workos_http_request, opts})
      end

      if is_pid(mock_store) do
        Agent.get_and_update(mock_store, fn
          [{:repeat, _} = response | rest] -> {response, [response | rest]}
          [response | rest] -> {response, rest}
          [] -> {:no_mocked_response, []}
        end)
        |> case do
          :no_mocked_response -> raise "No mocked WorkOS HTTP responses were configured"
          {:repeat, response_fun} when is_function(response_fun, 1) -> response_fun.(opts)
          response_fun when is_function(response_fun, 1) -> response_fun.(opts)
          response -> response
        end
      else
        raise "No WorkOS mock store configured"
      end
    end
  end

  setup do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_http_backoff_ms = Application.get_env(:fizz, :workos_http_backoff_ms)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)
    mock_store = start_supervised!({Agent, fn -> [] end})

    :persistent_term.put({__MODULE__, :owner}, self())
    :persistent_term.put({__MODULE__, :mock_store}, mock_store)

    Application.put_env(:fizz, :workos_http_client_module, ReqMock)
    Application.put_env(:fizz, :workos_http_backoff_ms, 0)

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.Accounts.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      restore_env(:fizz, :workos_http_backoff_ms, previous_workos_http_backoff_ms)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
      :persistent_term.erase({__MODULE__, :owner})
      :persistent_term.erase({__MODULE__, :mock_store})
    end)

    :ok
  end

  describe "authenticated users management page" do
    setup :register_and_log_in_user

    test "renders management widgets and native credentials tab", %{conn: conn} do
      put_http_responses([
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        widget_response("widget_token_123"),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        widget_response("widget_token_123")
      ])

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
               "#settings-tab-api-keys"
             )

      view
      |> element("#settings-tab-api-keys")
      |> render_click()

      assert has_element?(view, "#user-management-credentials-section")
      assert has_element?(view, "#user-management-credentials-empty")
    end

    test "creates, rotates, and deletes credentials in credentials tab", %{conn: conn} do
      put_http_responses([
        {:repeat, &org_scoped_credential_flow_response/1}
      ])

      {:ok, view, _html} = live(conn, ~p"/settings/")

      view
      |> element("#settings-tab-api-keys")
      |> render_click()

      view
      |> element("#open-create-credential-modal")
      |> render_click()

      assert has_element?(view, "#create-credential-form")

      view
      |> element("#create-credential-form")
      |> render_submit(%{
        "credential" => %{
          "provider" => "openai_api_key",
          "provider_label" => "OpenAI Key",
          "provider_custom_name" => "",
          "secret" => "sk-openai-1"
        }
      })

      credential = Repo.one!(ApiCredential)
      assert has_element?(view, "#credential-#{credential.id}")

      view
      |> element("#rotate-credential-#{credential.id}")
      |> render_click()

      view
      |> element("#rotate-credential-form")
      |> render_submit(%{
        "rotate_credential" => %{
          "provider_label" => "OpenAI Key Rotated",
          "provider_custom_name" => "",
          "secret" => "sk-openai-2"
        }
      })

      assert has_element?(view, "#credential-#{credential.id}")

      view
      |> element("#delete-credential-#{credential.id}")
      |> render_click()

      view
      |> element("#delete-credential-modal .btn-error")
      |> render_click()

      refute Repo.get(ApiCredential, credential.id)
    end

    test "switches organizations and refreshes token", %{conn: conn, user: user} do
      put_http_responses([
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"},
          %{"id" => "om_2", "organization_id" => "org_456", "status" => "active"}
        ]),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        widget_response("widget_token_123"),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"},
          %{"id" => "om_2", "organization_id" => "org_456", "status" => "active"}
        ]),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ]),
        widget_response("widget_token_123"),
        memberships_response([
          %{"id" => "om_2", "organization_id" => "org_456", "status" => "active"}
        ]),
        memberships_response([
          %{"id" => "om_2", "organization_id" => "org_456", "status" => "active"}
        ]),
        widget_response("widget_token_456")
      ])

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

      requests = receive_workos_requests(11)

      assert Enum.any?(requests, fn request ->
               request[:url] == "/widgets/token" and
                 request[:json] == %{
                   organization_id: "org_456",
                   scopes: [],
                   user_id: user.workos_user_id
                 }
             end)
    end

    test "auto-provisions a personal organization when user has none", %{conn: conn, user: user} do
      org_name = "#{String.split(user.email, "@") |> List.first()}'s Organization"

      auto_provision_responses = fn ->
        [
          # list_user_workos_organizations → empty
          memberships_response([]),
          # create_workos_organization → new org
          {:ok,
           %Req.Response{
             status: 201,
             body: %{"id" => "org_personal", "name" => org_name}
           }},
          # create_organization_membership → owner
          {:ok,
           %Req.Response{
             status: 201,
             body: %{
               "id" => "om_personal",
               "user_id" => user.workos_user_id,
               "organization_id" => "org_personal",
               "status" => "active",
               "role" => %{"slug" => "owner"}
             }
           }},
          # build_scope_for_workspace context check
          memberships_response([
            %{
              "id" => "om_personal",
              "organization_id" => "org_personal",
              "status" => "active",
              "role" => %{"slug" => "owner"}
            }
          ]),
          # user_has_organization_membership? check for widget token
          memberships_response([
            %{
              "id" => "om_personal",
              "organization_id" => "org_personal",
              "status" => "active",
              "role" => %{"slug" => "owner"}
            }
          ]),
          # generate_widget_token
          widget_response("widget_token_personal")
        ]
      end

      # Static render + connected mount
      put_http_responses(auto_provision_responses.() ++ auto_provision_responses.())

      {:ok, view, _html} = live(conn, ~p"/settings/")

      refute has_element?(view, "#user-management-no-organization")
      assert has_element?(view, "#user-management-page")
    end

    test "shows fallback state when auto-provisioning fails", %{conn: conn} do
      provisioning_failure_responses = [
        # list_user_workos_organizations → empty
        memberships_response([]),
        # create_workos_organization → error
        {:ok, %Req.Response{status: 500, body: %{"message" => "Internal server error"}}}
      ]

      # Static render + connected mount
      put_http_responses(provisioning_failure_responses ++ provisioning_failure_responses)

      {:ok, view, _html} = live(conn, ~p"/settings/")

      assert has_element?(view, "#user-management-no-organization")
      refute has_element?(view, "#user-management-widget-error")
    end
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/settings/")
  end

  defp memberships_response(memberships) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{"data" => memberships}
     }}
  end

  defp widget_response(token) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{"token" => token}
     }}
  end

  defp receive_workos_requests(0), do: []

  defp receive_workos_requests(count) when is_integer(count) and count > 0 do
    Enum.map(1..count, fn _index ->
      assert_receive {:workos_http_request, request}
      request
    end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp put_http_responses(responses) do
    mock_store = :persistent_term.get({__MODULE__, :mock_store})
    Agent.update(mock_store, fn _ -> responses end)
  end

  defp org_scoped_credential_flow_response(opts) do
    case {opts[:method], opts[:url]} do
      {:get, "/user_management/organization_memberships"} ->
        memberships_response([
          %{"id" => "om_1", "organization_id" => "org_123", "status" => "active"}
        ])

      {:post, "/widgets/token"} ->
        widget_response("widget_token_123")

      {:post, "/vault/v1/kv"} ->
        {:ok,
         %Req.Response{
           status: 201,
           body: %{
             "id" => "vault_obj_123",
             "metadata" => %{"version_id" => "version_1"}
           }
         }}

      {:put, "/vault/v1/kv/vault_obj_123"} ->
        {:ok, %Req.Response{status: 200, body: %{"metadata" => %{"version_id" => "version_2"}}}}

      {:delete, "/vault/v1/kv/vault_obj_123"} ->
        {:ok, %Req.Response{status: 204, body: %{}}}

      _ ->
        {:ok, %Req.Response{status: 200, body: %{}}}
    end
  end
end
