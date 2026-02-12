defmodule Fizz.SpritesTest do
  use Fizz.DataCase, async: false

  alias Fizz.Accounts.Scope
  alias Fizz.Accounts.WorkspaceMembership
  alias Fizz.Repo
  alias Fizz.Sprites

  import Fizz.AccountsFixtures

  setup do
    previous_provider = Application.get_env(:fizz, :sprites_provider_module)
    previous_api_key = Application.get_env(:fizz, :sprites_api_key)

    mock_store = start_supervised!({Agent, fn -> %{} end})
    Fizz.SpritesProviderMock.configure(self(), mock_store)

    Application.put_env(:fizz, :sprites_provider_module, Fizz.SpritesProviderMock)
    Application.put_env(:fizz, :sprites_api_key, "sprites_test_token")

    on_exit(fn ->
      restore_env(:fizz, :sprites_provider_module, previous_provider)
      restore_env(:fizz, :sprites_api_key, previous_api_key)
      Fizz.SpritesProviderMock.reset()
    end)

    admin_scope = organization_scope_fixture()
    workspace = workspace_fixture(admin_scope, %{name: "Sprites Workspace"})

    sprite_scope =
      admin_scope
      |> Scope.with_workspace(workspace)
      |> Scope.with_workspace_role(:admin)

    %{sprite_scope: sprite_scope, workspace: workspace}
  end

  test "create_sprite/3 and list_sprites/2 create workspace-owned aliases", %{
    sprite_scope: sprite_scope
  } do
    assert {:ok, sprite} =
             Sprites.create_sprite(sprite_scope, %{
               "display_name" => "Research Sandbox",
               "description" => "shared workspace sprite"
             })

    assert sprite.workspace_id == sprite_scope.workspace.id
    assert sprite.status == "ready"
    assert sprite.url_auth_mode == "bearer"
    assert sprite.sprite_name =~ ~r/^fizz-research-sandbox-[a-z0-9]+$/

    assert {:ok, [listed_sprite]} = Sprites.list_sprites(sprite_scope)
    assert listed_sprite.id == sprite.id
    assert listed_sprite.status == "ready"

    assert_receive {:sprites_provider_call, {:create_sprite, _sprite_name, _config}}
    assert_receive {:sprites_provider_call, {:update_network_policy, _sprite_name, _policy}}
    assert_receive {:sprites_provider_call, {:update_url_settings, _sprite_name, _settings}}
  end

  test "create_sprite/3 keeps successful creations when post-create setup fails", %{
    sprite_scope: sprite_scope
  } do
    Fizz.SpritesProviderMock.put_responses(:update_network_policy, [
      {:error, :temporarily_unavailable}
    ])

    Fizz.SpritesProviderMock.put_responses(:update_url_settings, [{:error, :sprite_not_ready}])
    Fizz.SpritesProviderMock.put_responses(:get_url_settings, [{:error, :sprite_not_ready}])

    assert {:ok, sprite} =
             Sprites.create_sprite(sprite_scope, %{
               "display_name" => "Provisioning Delay"
             })

    assert sprite.status == "ready"
    assert is_list(sprite.metadata["provisioning_warnings"])

    assert Enum.map(sprite.metadata["provisioning_warnings"], & &1["step"]) == [
             "update_network_policy",
             "update_url_settings",
             "get_url_settings"
           ]
  end

  test "members can execute commands but cannot manage sprite lifecycle", %{
    sprite_scope: sprite_scope,
    workspace: workspace
  } do
    assert {:ok, sprite} =
             Sprites.create_sprite(sprite_scope, %{
               "display_name" => "Execution Sandbox"
             })

    member_scope = member_scope_for_workspace(workspace, sprite_scope.organization_id)

    assert {:ok, %{exit_code: 0, output: "ok\n"}} =
             Sprites.run_command(member_scope, sprite.id, %{
               "command" => "echo",
               "args" => "hello"
             })

    assert {:error, :forbidden} = Sprites.destroy_sprite(member_scope, sprite.id)

    assert {:error, :forbidden} =
             Sprites.update_network_policy(member_scope, sprite.id, %{preset: "minimal_agent"})
  end

  test "open_console_client/5 creates a session and streams output", %{sprite_scope: sprite_scope} do
    assert {:ok, sprite} =
             Sprites.create_sprite(sprite_scope, %{
               "display_name" => "Console Sandbox"
             })

    assert {:ok, session} =
             Sprites.open_console_client(sprite_scope, sprite.id, "pane-1", "client-a",
               focused: true
             )

    session_id = session.session_id
    console_pid = Fizz.Sprites.Console.Registry.whereis(session_id)

    assert :ok =
             Sprites.send_console_input(
               sprite_scope,
               sprite.id,
               session_id,
               "client-a",
               "echo hi\n"
             )

    assert_receive {:console_session_event, ^session_id,
                    %{type: "output_chunk", chunk: %{stream: "stdout", data: "echo hi\n"}}}

    assert :ok = Sprites.terminate_console_session(sprite_scope, sprite.id, session_id)

    assert_receive {:sprites_provider_call, {:kill_session, _sprite_name, provider_session_id}}
    assert is_binary(provider_session_id)

    assert_receive {:console_session_event, ^session_id,
                    %{type: "session_exit", reason: "terminated_by_user"}}

    if is_pid(console_pid) do
      monitor_ref = Process.monitor(console_pid)
      assert_receive {:DOWN, ^monitor_ref, :process, ^console_pid, _reason}
    end
  end

  test "open_console_client/5 reuses running pane sessions", %{
    sprite_scope: sprite_scope
  } do
    assert {:ok, sprite} =
             Sprites.create_sprite(sprite_scope, %{
               "display_name" => "Kill Session Sprite"
             })

    assert {:ok, first} =
             Sprites.open_console_client(sprite_scope, sprite.id, "pane-1", "client-a",
               focused: true
             )

    assert {:ok, second} =
             Sprites.open_console_client(sprite_scope, sprite.id, "pane-1", "client-a",
               focused: true
             )

    assert first.session_id == second.session_id
    assert :ok = Sprites.terminate_console_session(sprite_scope, sprite.id, first.session_id)
  end

  test "open_console_client/5 defaults bash sessions to interactive mode", %{
    sprite_scope: sprite_scope
  } do
    assert {:ok, sprite} =
             Sprites.create_sprite(sprite_scope, %{
               "display_name" => "Interactive Console Sprite"
             })

    assert {:ok, _session} =
             Sprites.open_console_client(sprite_scope, sprite.id, "pane-1", "client-a",
               focused: true
             )

    assert_receive {:sprites_provider_call, {:start_console, _sprite_name, "bash", ["-i"]}}
    assert {:ok, [session]} = Sprites.list_sessions(sprite_scope, sprite.id)
    assert :ok = Sprites.terminate_console_session(sprite_scope, sprite.id, session.id)
  end

  test "session server child spec does not restart exited sessions" do
    assert %{restart: :temporary} = Fizz.Sprites.Console.SessionServer.child_spec([])
  end

  test "list_sessions/3 reads persisted console sessions", %{sprite_scope: sprite_scope} do
    assert {:ok, sprite} =
             Sprites.create_sprite(sprite_scope, %{
               "display_name" => "Session Source Sprite"
             })

    assert {:ok, opened} =
             Sprites.open_console_client(sprite_scope, sprite.id, "pane-1", "client-a",
               focused: true
             )

    assert {:ok, [session]} = Sprites.list_sessions(sprite_scope, sprite.id)
    assert session.id == opened.session_id
    assert session.state in ["starting", "attached", "grace_detaching", "detached"]
    assert session.interactive_command == "bash"
    assert :ok = Sprites.terminate_console_session(sprite_scope, sprite.id, opened.session_id)
  end

  defp member_scope_for_workspace(workspace, organization_id) do
    user = user_fixture()

    %WorkspaceMembership{workspace_id: workspace.id, user_id: user.id}
    |> WorkspaceMembership.changeset(%{role: :member})
    |> Repo.insert!()

    Scope.for_user(user)
    |> Scope.with_organization_id(organization_id)
    |> Scope.with_organization_role(:member)
    |> Scope.with_workspace(workspace)
    |> Scope.with_workspace_role(:member)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
