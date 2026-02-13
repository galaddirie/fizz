defmodule FizzWeb.SpritesLiveTest do
  use FizzWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope

  setup do
    previous_sprites_config = Application.get_env(:fizz, :sprites)
    previous_sprites_sdk_module = Application.get_env(:fizz, :sprites_sdk_module)
    previous_workos_client_module = Application.get_env(:fizz, :workos_client_module)

    sprites_mock_store =
      start_supervised!(%{id: :sprites_mock_store, start: {Agent, :start_link, [fn -> %{} end]}})

    workos_mock_store =
      start_supervised!(%{id: :workos_mock_store, start: {Agent, :start_link, [fn -> %{} end]}})

    Fizz.SpritesSDKMock.configure(self(), sprites_mock_store)
    Fizz.WorkOSClientMock.configure(self(), workos_mock_store)

    Application.put_env(:fizz, :sprites_sdk_module, Fizz.SpritesSDKMock)
    Application.put_env(:fizz, :workos_client_module, Fizz.WorkOSClientMock)

    Application.put_env(:fizz, :sprites,
      api_key: "sprites_test_key",
      base_url: "https://api.sprites.dev",
      name_prefix: "fizz-test",
      cmd_timeout_ms: 30_000
    )

    on_exit(fn ->
      restore_env(:fizz, :sprites, previous_sprites_config)
      restore_env(:fizz, :sprites_sdk_module, previous_sprites_sdk_module)
      restore_env(:fizz, :workos_client_module, previous_workos_client_module)
      Fizz.SpritesSDKMock.reset()
      Fizz.WorkOSClientMock.reset()
    end)

    :ok
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/workos"}}} = live(conn, ~p"/sprites")
  end

  describe "authenticated dashboard" do
    setup [:register_and_log_in_user, :prepare_workspace_and_workos]

    test "renders page with org and workspace selectors", %{conn: conn} do
      seed_dashboard_defaults()

      {:ok, view, _html} = live(conn, ~p"/sprites")

      assert has_element?(view, "#sprites-page")
      assert has_element?(view, "#sprites-workspace-form")
      assert has_element?(view, "#sprites-org-select")
      assert has_element?(view, "#sprites-workspace-select")
    end

    test "shows config warning when sprites not configured", %{conn: conn} do
      Application.put_env(:fizz, :sprites,
        api_key: nil,
        base_url: "https://api.sprites.dev",
        name_prefix: "fizz-test",
        cmd_timeout_ms: 30_000
      )

      seed_dashboard_defaults()

      {:ok, view, _html} = live(conn, ~p"/sprites")

      assert has_element?(view, "#sprites-config-warning")
    end

    test "has sprite action buttons", %{conn: conn} do
      seed_dashboard_defaults()

      {:ok, view, _html} = live(conn, ~p"/sprites")

      assert has_element?(view, "#sprites-ensure-workspace")
      assert has_element?(view, "#sprites-destroy-workspace")
    end

    test "ensure and destroy actions call Sprites SDK", %{conn: conn} do
      seed_dashboard_defaults()

      Fizz.SpritesSDKMock.put_response(:get_sprite, {:ok, %{name: "sprite-1", status: "running"}})

      {:ok, view, _html} = live(conn, ~p"/sprites")

      view
      |> element("#sprites-ensure-workspace")
      |> render_click()

      assert_receive {:sprites_sdk_call, :get_sprite, _args}

      view
      |> element("#sprites-destroy-workspace")
      |> render_click()

      assert_receive {:sprites_sdk_call, :destroy, _args}
    end

    test "runs command through exec form", %{conn: conn} do
      seed_dashboard_defaults()

      Fizz.SpritesSDKMock.put_response(:get_sprite, {:ok, %{name: "sprite-1", status: "running"}})

      Fizz.SpritesSDKMock.put_response(:cmd, fn _sprite, "bash", ["-lc", "echo hello"], _opts ->
        {"hello\n", 0}
      end)

      {:ok, view, _html} = live(conn, ~p"/sprites")

      view
      |> element("#sprites-exec-form")
      |> render_submit(%{"exec" => %{"command" => "echo hello"}})

      assert has_element?(view, "#sprites-exec-output")
      assert has_element?(view, "#sprites-last-exit")
      assert_receive {:sprites_sdk_call, :cmd, _args}
    end

    test "opens console and writes stdin", %{conn: conn} do
      seed_dashboard_defaults()
      test_pid = self()

      Fizz.SpritesSDKMock.put_response(:get_sprite, {:ok, %{name: "sprite-1", status: "running"}})

      Fizz.SpritesSDKMock.put_response(:spawn, fn _sprite, _command, _args, opts ->
        command = Fizz.SpritesSDKMock.build_command(Keyword.fetch!(opts, :owner))
        send(test_pid, {:mock_console_command, command})
        {:ok, command}
      end)

      {:ok, view, _html} = live(conn, ~p"/sprites")

      view
      |> element("#sprites-open-console")
      |> render_click()

      assert_receive {:mock_console_command, command}

      :ok = Fizz.SpritesSDKMock.emit_stdout(command, "console-ready\n")

      view
      |> element("#sprites-console-form")
      |> render_submit(%{"console_input" => %{"input" => "pwd"}})

      assert has_element?(view, "#sprites-console-stream")
      assert_receive {:sprites_sdk_call, :write, [_command, "pwd\n"]}
    end

    test "creates and restores checkpoints", %{conn: conn} do
      seed_dashboard_defaults()

      Fizz.SpritesSDKMock.put_responses(:list_checkpoints, [
        {:ok, [%{id: "cp_1", create_time: nil, comment: nil, history: []}]},
        {:ok, [%{id: "cp_1", create_time: nil, comment: nil, history: []}]},
        {:ok, [%{id: "cp_1", create_time: nil, comment: nil, history: []}]}
      ])

      Fizz.SpritesSDKMock.put_response(:get_sprite, {:ok, %{name: "sprite-1", status: "running"}})

      Fizz.SpritesSDKMock.put_response(
        :create_checkpoint,
        {:ok, [%{type: "info", data: "created", error: nil}]}
      )

      Fizz.SpritesSDKMock.put_response(
        :restore_checkpoint,
        {:ok, [%{type: "info", data: "restored", error: nil}]}
      )

      {:ok, view, _html} = live(conn, ~p"/sprites")

      view
      |> element("#sprites-checkpoint-form")
      |> render_submit(%{"checkpoint" => %{"comment" => "before"}})

      assert_receive {:sprites_sdk_call, :create_checkpoint, _args}

      view
      |> element("#sprites-restore-cp_1")
      |> render_click()

      assert_receive {:sprites_sdk_call, :restore_checkpoint, _args}
    end
  end

  test "shows config warning when sprites token is missing", %{conn: conn} do
    Application.put_env(:fizz, :sprites,
      api_key: nil,
      base_url: "https://api.sprites.dev",
      name_prefix: "fizz-test",
      cmd_timeout_ms: 30_000
    )

    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
    prepare_workspace_and_workos(%{user: user})

    {:ok, view, _html} = live(conn, ~p"/sprites")

    assert has_element?(view, "#sprites-config-warning")
    assert has_element?(view, "#sprites-workspace-form")
  end

  defp prepare_workspace_and_workos(%{user: user} = context) do
    organization_id = "org_123"

    owner_scope =
      Scope.for_user(user)
      |> Scope.with_organization_id(organization_id)
      |> Scope.with_organization_role(:owner)

    {:ok, workspace} = Accounts.create_workspace(owner_scope, %{name: "Client A"})

    membership =
      %{
        "id" => "om_1",
        "organization_id" => organization_id,
        "status" => "active",
        "role" => %{"slug" => "owner"}
      }

    Fizz.WorkOSClientMock.put_responses(%{
      list_user_organization_memberships: List.duplicate({:ok, [membership]}, 20),
      get_user_organization_membership: List.duplicate({:ok, membership}, 20)
    })

    Map.merge(context, %{workspace: workspace, organization_id: organization_id})
  end

  defp seed_dashboard_defaults do
    Fizz.SpritesSDKMock.put_responses(%{
      list: List.duplicate({:ok, []}, 20),
      list_sessions: List.duplicate({:ok, []}, 20),
      list_checkpoints: List.duplicate({:ok, []}, 20),
      get_sprite: List.duplicate({:ok, %{name: "sprite-1", status: "running"}}, 20),
      destroy: List.duplicate(:ok, 20),
      spawn:
        List.duplicate(
          fn _sprite, _command, _args, opts ->
            {:ok, Fizz.SpritesSDKMock.build_command(Keyword.fetch!(opts, :owner))}
          end,
          20
        ),
      write: List.duplicate(:ok, 20),
      create_checkpoint: List.duplicate({:ok, []}, 20),
      restore_checkpoint: List.duplicate({:ok, []}, 20)
    })
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
