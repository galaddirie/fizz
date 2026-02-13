defmodule Fizz.Sprites.WorkspaceServerTest do
  use ExUnit.Case, async: false

  alias Fizz.Sprites.Workspace
  alias Fizz.Sprites.Broker.WorkspaceServer

  setup do
    previous_sprites_config = Application.get_env(:fizz, :sprites)
    previous_sprites_sdk_module = Application.get_env(:fizz, :sprites_sdk_module)
    mock_store = start_supervised!({Agent, fn -> %{} end})

    Fizz.SpritesSDKMock.configure(self(), mock_store)

    Application.put_env(:fizz, :sprites,
      api_key: "sprites_test_key",
      base_url: "https://api.sprites.dev",
      name_prefix: "fizz-test",
      cmd_timeout_ms: 30_000
    )

    Application.put_env(:fizz, :sprites_sdk_module, Fizz.SpritesSDKMock)

    on_exit(fn ->
      restore_env(:fizz, :sprites, previous_sprites_config)
      restore_env(:fizz, :sprites_sdk_module, previous_sprites_sdk_module)
      Fizz.SpritesSDKMock.reset()
    end)

    :ok
  end

  test "ensure_sprite creates the sprite when it does not exist" do
    workspace = Workspace.new("org:org_123", "default")

    Fizz.SpritesSDKMock.put_responses(%{
      get_sprite: [
        {:error, {:not_found, %{}}},
        {:ok, %{name: workspace.sprite_name, status: "running"}}
      ],
      create: [{:ok, %{name: workspace.sprite_name}}]
    })

    pid = start_supervised!({WorkspaceServer, workspace: workspace})

    assert {:ok, %{name: name, status: "running"}} = GenServer.call(pid, :ensure_sprite)
    assert name == workspace.sprite_name

    assert_receive {:sprites_sdk_call, :get_sprite, _args}
    assert_receive {:sprites_sdk_call, :create, _args}
  end

  test "exec_shell runs command via Sprites SDK" do
    workspace = Workspace.new("org:org_123", "default")

    Fizz.SpritesSDKMock.put_responses(%{
      get_sprite: List.duplicate({:ok, %{name: workspace.sprite_name, status: "running"}}, 4),
      cmd: [{"hello\n", 0}]
    })

    pid = start_supervised!({WorkspaceServer, workspace: workspace})

    assert {:ok, %{stdout: "hello\n", exit_code: 0}} =
             GenServer.call(pid, {:exec_shell, "echo hello", []})

    assert_receive {:sprites_sdk_call, :cmd, [_sprite, "bash", ["-lc", "echo hello"], _opts]}
  end

  test "list_checkpoints returns checkpoints from sdk" do
    workspace = Workspace.new("org:org_123", "default")

    Fizz.SpritesSDKMock.put_responses(%{
      get_sprite: List.duplicate({:ok, %{name: workspace.sprite_name, status: "running"}}, 4),
      list_checkpoints: [{:ok, [%{id: "cp_1", comment: "seed"}]}]
    })

    pid = start_supervised!({WorkspaceServer, workspace: workspace})

    assert {:ok, [%{id: "cp_1", comment: "seed"}]} = GenServer.call(pid, :list_checkpoints)
    assert_receive {:sprites_sdk_call, :list_checkpoints, _args}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
