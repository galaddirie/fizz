defmodule Fizz.Sprites do
  @moduledoc """
  Sprite orchestration context.

  All operations require a resolved `%Scope{}` with an organization and workspace.
  Authorization flows through the Accounts Scope chain.
  """

  alias Fizz.Accounts.Scope
  alias Fizz.Accounts.Workspace, as: AccountsWorkspace
  alias Fizz.Repo
  alias Fizz.Sprites.{Broker, Config, Name, Workspace}
  alias Fizz.Sprites.Sprite

  @spec configured?() :: boolean()
  def configured?, do: Config.configured?()

  @spec ensure_sprite(Scope.t()) :: {:ok, map()} | {:error, term()}
  def ensure_sprite(%Scope{workspace: %AccountsWorkspace{} = ws} = scope) do
    with :ok <- require_configured(),
         :ok <- require_member(scope),
         sprites_ws <- sprites_workspace(ws),
         {:ok, sprite} <- Broker.ensure_sprite(sprites_ws),
         {:ok, _record} <- upsert_workspace_sprite(ws, sprites_ws.sprite_name, "available") do
      {:ok, sprite}
    end
  end

  def ensure_sprite(_scope), do: {:error, :workspace_scope_required}

  @spec destroy_sprite(Scope.t()) :: :ok | {:error, term()}
  def destroy_sprite(%Scope{workspace: %AccountsWorkspace{} = ws} = scope) do
    with :ok <- require_configured(),
         :ok <- require_admin(scope),
         sprites_ws <- sprites_workspace(ws),
         :ok <- Broker.destroy_sprite(sprites_ws),
         {:ok, _record} <- upsert_workspace_sprite(ws, sprites_ws.sprite_name, "deleted") do
      :ok
    end
  end

  def destroy_sprite(_scope), do: {:error, :workspace_scope_required}

  @spec workspace_sprite_name(Scope.t()) :: String.t() | nil
  def workspace_sprite_name(%Scope{workspace: %AccountsWorkspace{} = ws}) do
    ws
    |> sprites_workspace()
    |> Map.fetch!(:sprite_name)
  end

  def workspace_sprite_name(_scope), do: nil

  @spec exec(Scope.t(), String.t(), keyword()) ::
          {:ok, %{stdout: binary(), exit_code: non_neg_integer()}} | {:error, term()}
  def exec(%Scope{workspace: %AccountsWorkspace{} = ws} = scope, command, opts \\ [])
      when is_binary(command) do
    with :ok <- require_configured(),
         :ok <- require_member(scope),
         sprites_ws <- sprites_workspace(ws),
         {:ok, result} <- Broker.exec_shell(sprites_ws, command, opts) do
      {:ok, result}
    end
  end

  @spec spawn_console(Scope.t(), pid(), keyword()) :: {:ok, term()} | {:error, term()}
  def spawn_console(scope, owner, opts \\ [])

  def spawn_console(%Scope{workspace: %AccountsWorkspace{} = ws} = scope, owner, opts) do
    with :ok <- require_configured(),
         :ok <- require_member(scope),
         sprites_ws <- sprites_workspace(ws),
         {:ok, command} <- Broker.spawn_console(sprites_ws, owner, opts) do
      {:ok, command}
    end
  end

  def spawn_console(_scope, _owner, _opts), do: {:error, :workspace_scope_required}

  @spec attach_console(Scope.t(), String.t(), pid(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def attach_console(
        %Scope{workspace: %AccountsWorkspace{} = ws} = scope,
        session_id,
        owner,
        opts \\ []
      )
      when is_binary(session_id) do
    with :ok <- require_configured(),
         :ok <- require_member(scope),
         sprites_ws <- sprites_workspace(ws),
         {:ok, command} <- Broker.attach_console(sprites_ws, session_id, owner, opts) do
      {:ok, command}
    end
  end

  @spec write_console(term(), iodata()) :: :ok | {:error, term()}
  def write_console(command, data), do: sprites_sdk().write(command, data)

  @spec close_console(term()) :: :ok
  def close_console(command), do: sprites_sdk().close_stdin(command)

  @spec resize_console(term(), pos_integer(), pos_integer()) :: :ok
  def resize_console(command, rows, cols), do: sprites_sdk().resize(command, rows, cols)

  @spec await_console(term(), timeout()) :: {:ok, non_neg_integer()} | {:error, term()}
  def await_console(command, timeout \\ :infinity),
    do: sprites_sdk().await(command, timeout)

  @spec list_sessions(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def list_sessions(%Scope{workspace: %AccountsWorkspace{} = ws} = scope) do
    with :ok <- require_configured(),
         :ok <- require_member(scope),
         sprites_ws <- sprites_workspace(ws),
         {:ok, sessions} <- Broker.list_sessions(sprites_ws) do
      {:ok, Enum.map(sessions, &session_to_map/1)}
    end
  end

  def list_sessions(_scope), do: {:error, :workspace_scope_required}

  @spec list_checkpoints(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def list_checkpoints(%Scope{workspace: %AccountsWorkspace{} = ws} = scope) do
    with :ok <- require_configured(),
         :ok <- require_member(scope),
         sprites_ws <- sprites_workspace(ws),
         {:ok, checkpoints} <- Broker.list_checkpoints(sprites_ws) do
      {:ok, Enum.map(checkpoints, &checkpoint_to_map/1)}
    end
  end

  def list_checkpoints(_scope), do: {:error, :workspace_scope_required}

  @spec create_checkpoint(Scope.t(), String.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def create_checkpoint(%Scope{workspace: %AccountsWorkspace{} = ws} = scope, comment \\ nil) do
    with :ok <- require_configured(),
         :ok <- require_member(scope),
         sprites_ws <- sprites_workspace(ws),
         {:ok, messages} <- Broker.create_checkpoint(sprites_ws, comment) do
      {:ok, Enum.map(messages, &checkpoint_message_to_map/1)}
    end
  end

  @spec restore_checkpoint(Scope.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def restore_checkpoint(
        %Scope{workspace: %AccountsWorkspace{} = ws} = scope,
        checkpoint_id
      )
      when is_binary(checkpoint_id) do
    with :ok <- require_configured(),
         :ok <- require_member(scope),
         sprites_ws <- sprites_workspace(ws),
         {:ok, messages} <- Broker.restore_checkpoint(sprites_ws, checkpoint_id) do
      {:ok, Enum.map(messages, &checkpoint_message_to_map/1)}
    end
  end

  @spec list_workspace_sprites(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def list_workspace_sprites(%Scope{organization_id: org_id} = scope)
      when is_binary(org_id) do
    with :ok <- require_configured(),
         :ok <- require_member(scope) do
      list_sprites_for_tenant("org:#{org_id}")
    end
  end

  def list_workspace_sprites(_scope), do: {:error, :organization_scope_required}

  # Internal helpers

  defp sprites_workspace(%AccountsWorkspace{} = ws) do
    tenant_id = "org:#{ws.workos_organization_id}"

    %Workspace{
      workspace_id: Name.workspace_id(tenant_id, ws.slug),
      tenant_id: tenant_id,
      workspace_key: ws.slug,
      sprite_name: Name.sprite_name(tenant_id, ws.slug),
      tenant_prefix: Name.tenant_prefix(tenant_id)
    }
  end

  defp upsert_workspace_sprite(%AccountsWorkspace{} = ws, sprite_name, status)
       when is_binary(sprite_name) and is_binary(status) do
    existing = Repo.get_by(Sprite, name: sprite_name)

    sprite =
      existing ||
        %Sprite{
          name: sprite_name,
          workspace_id: ws.id
        }

    sprite
    |> Sprite.changeset(%{name: sprite_name, status: status, workspace_id: ws.id})
    |> Repo.insert_or_update()
  end

  defp require_member(%Scope{} = scope) do
    if Scope.organization_member?(scope) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp require_admin(%Scope{} = scope) do
    if Scope.organization_admin?(scope) or Scope.workspace_admin?(scope) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp require_configured do
    if configured?() do
      :ok
    else
      {:error, :sprites_not_configured}
    end
  end

  defp list_sprites_for_tenant(tenant_id) do
    client = sprites_sdk().new(Config.api_key(), base_url: Config.base_url())

    with {:ok, sprites} <- sprites_sdk().list(client, prefix: Name.tenant_prefix(tenant_id)) do
      mapped =
        sprites
        |> Enum.map(&sprite_to_map/1)
        |> Enum.sort_by(& &1.name)

      {:ok, mapped}
    end
  rescue
    error ->
      {:error, {:list_failed, Exception.message(error)}}
  end

  defp sprite_to_map(sprite) when is_map(sprite) do
    name = read_value(sprite, ["name", :name])
    status = read_value(sprite, ["status", :status])
    url = read_value(sprite, ["url", :url])
    url_settings = read_value(sprite, ["url_settings", :url_settings])

    %{
      id: name || "sprite-#{System.unique_integer([:positive])}",
      name: name || "unknown",
      status: status || "unknown",
      url: url,
      auth: read_value(url_settings, ["auth", :auth])
    }
  end

  defp session_to_map(session) do
    %{
      id: read_value(session, [:id, "id"]),
      command: read_value(session, [:command, "command"]),
      tty: read_value(session, [:tty, "tty"]) in [true, "true"],
      is_active: read_value(session, [:is_active, "is_active"]) in [true, "true"],
      last_activity: read_value(session, [:last_activity, "last_activity"]),
      bytes_per_second: read_value(session, [:bytes_per_second, "bytes_per_second"]) || 0
    }
  end

  defp checkpoint_to_map(checkpoint) do
    %{
      id: read_value(checkpoint, [:id, "id"]),
      create_time: read_value(checkpoint, [:create_time, "create_time"]),
      comment: read_value(checkpoint, [:comment, "comment"]),
      history: read_value(checkpoint, [:history, "history"]) || []
    }
  end

  defp checkpoint_message_to_map(message) do
    %{
      type: read_value(message, [:type, "type"]),
      data: read_value(message, [:data, "data"]),
      error: read_value(message, [:error, "error"])
    }
  end

  defp read_value(data, keys) when is_map(data) do
    Enum.find_value(keys, fn key -> Map.get(data, key) end)
  end

  defp read_value(_data, _keys), do: nil

  defp sprites_sdk do
    Application.get_env(:fizz, :sprites_sdk_module, Fizz.Integrations.SpritesSDK.Live)
  end
end
