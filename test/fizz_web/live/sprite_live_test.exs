defmodule FizzWeb.SpriteLiveTest do
  use FizzWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Fizz.Accounts
  alias Fizz.Accounts.Scope

  setup do
    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)
    previous_provider = Application.get_env(:fizz, :sprites_provider_module)
    previous_sprites_api_key = Application.get_env(:fizz, :sprites_api_key)

    workos_store = start_supervised!({Agent, fn -> [] end}, id: make_ref())
    sprites_store = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    Fizz.WorkOSHTTPMock.configure(self(), workos_store)
    Fizz.SpritesProviderMock.configure(self(), sprites_store)

    Application.put_env(:fizz, :workos_http_client_module, Fizz.WorkOSHTTPMock)
    Application.put_env(:fizz, :sprites_provider_module, Fizz.SpritesProviderMock)
    Application.put_env(:fizz, :sprites_api_key, "sprites_test_token")

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
      restore_env(:fizz, :sprites_provider_module, previous_provider)
      restore_env(:fizz, :sprites_api_key, previous_sprites_api_key)
      Fizz.WorkOSHTTPMock.reset()
      Fizz.SpritesProviderMock.reset()
    end)

    :ok
  end

  test "sprite routes require authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/workos"}}} = live(conn, ~p"/sprites")

    assert {:error, {:redirect, %{to: "/auth/workos"}}} =
             live(conn, ~p"/org/org_123/workspaces/ws_123/sprites")
  end

  describe "authenticated sprite flows" do
    setup :register_and_log_in_user

    test "hub redirects to first workspace sprite index", %{conn: conn, user: user} do
      organization_id = "org_sprite_hub_123"
      workspace = create_workspace_for_user(user, organization_id)

      put_workos_responses(
        Enum.flat_map(1..4, fn _ ->
          [
            memberships_response([
              %{
                "id" => "om_1",
                "organization_id" => organization_id,
                "status" => "active",
                "role" => %{"slug" => "owner"},
                "organization" => %{"name" => "Sprite Org"}
              }
            ])
          ]
        end)
      )

      expected_path = ~p"/org/#{organization_id}/workspaces/#{workspace.id}/sprites"

      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, ~p"/sprites")
    end

    test "index creates sprites and links to show page", %{conn: conn, user: user} do
      organization_id = "org_sprite_index_456"
      workspace = create_workspace_for_user(user, organization_id)

      put_workos_responses(
        Enum.flat_map(1..6, fn _ ->
          [
            memberships_response([
              %{
                "id" => "om_1",
                "organization_id" => organization_id,
                "status" => "active",
                "role" => %{"slug" => "owner"}
              }
            ])
          ]
        end)
      )

      {:ok, view, _html} =
        live(conn, ~p"/org/#{organization_id}/workspaces/#{workspace.id}/sprites")

      assert has_element?(view, "#sprite-index-page")
      assert has_element?(view, "#sprite-create-form")

      view
      |> element("#sprite-create-form")
      |> render_submit(%{
        "sprite" => %{
          "display_name" => "CI Sprite",
          "description" => "test sprite"
        }
      })

      assert has_element?(view, "#sprite-index-list tr")
      assert_receive {:sprites_provider_call, {:create_sprite, _sprite_name, _config}}
    end

    test "show page renders console and policy controls", %{conn: conn, user: user} do
      organization_id = "org_sprite_show_789"
      workspace = create_workspace_for_user(user, organization_id)

      put_workos_responses(
        Enum.flat_map(1..8, fn _ ->
          [
            memberships_response([
              %{
                "id" => "om_1",
                "organization_id" => organization_id,
                "status" => "active",
                "role" => %{"slug" => "owner"}
              }
            ])
          ]
        end)
      )

      sprite_scope =
        Scope.for_user(user)
        |> Scope.with_organization_id(organization_id)
        |> Scope.with_organization_role(:owner)
        |> Scope.with_workspace(workspace)
        |> Scope.with_workspace_role(:admin)

      {:ok, sprite} =
        Fizz.Sprites.create_sprite(sprite_scope, %{
          "display_name" => "Show Sprite"
        })

      {:ok, view, _html} =
        live(conn, ~p"/org/#{organization_id}/workspaces/#{workspace.id}/sprites/#{sprite.id}")

      assert has_element?(view, "#sprite-show-page")
      assert has_element?(view, "#sprite-console-v2")
      assert has_element?(view, "#sprite-console-terminal-pane-1")
      assert has_element?(view, "#sprite-policy-form")
      assert has_element?(view, "#sprite-url-form")
      assert has_element?(view, "#sprite-checkpoint-form")
    end
  end

  defp create_workspace_for_user(user, organization_id) do
    scope =
      Scope.for_user(user)
      |> Scope.with_organization_id(organization_id)
      |> Scope.with_organization_role(:owner)

    {:ok, workspace} =
      Accounts.create_workspace(scope, %{
        name: "Workspace #{System.unique_integer([:positive])}"
      })

    workspace
  end

  defp put_workos_responses(responses) do
    Fizz.WorkOSHTTPMock.put_responses(responses)
  end

  defp memberships_response(memberships) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{"data" => memberships}
     }}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
