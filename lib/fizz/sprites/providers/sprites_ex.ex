defmodule Fizz.Sprites.Providers.SpritesEx do
  @moduledoc """
  `Fizz.Sprites.Provider` implementation backed by the `sprites-ex` client.
  """

  @behaviour Fizz.Sprites.Provider

  @default_base_url "https://api.sprites.dev"

  @impl true
  def configured? do
    token = api_token()
    is_binary(token) and byte_size(token) > 0
  end

  @impl true
  def create_sprite(name, config) when is_binary(name) and is_map(config) do
    with {:ok, client} <- client(),
         {:ok, sprite} <- Sprites.create(client, name, config: config) do
      {:ok,
       %{
         id: sprite.id,
         name: sprite.name,
         status: sprite.status,
         config: sprite.config,
         environment: sprite.environment
       }}
    end
  end

  @impl true
  def destroy_sprite(name) when is_binary(name) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)
      Sprites.destroy(sprite)
    end
  end

  @impl true
  def get_sprite(name) when is_binary(name) do
    with {:ok, client} <- client() do
      Sprites.get_sprite(client, name)
    end
  end

  @impl true
  def run_command(name, command, args, opts)
      when is_binary(name) and is_binary(command) and is_list(args) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)
      {output, exit_code} = Sprites.cmd(sprite, command, args, opts)
      {:ok, %{output: output, exit_code: exit_code}}
    end
  rescue
    error ->
      {:error, error}
  end

  @impl true
  def start_console(name, command, args, opts)
      when is_binary(name) and is_binary(command) and is_list(args) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)

      existing_session_ids = list_session_ids(sprite)

      case Sprites.spawn(sprite, command, args, Keyword.put(opts, :detachable, true)) do
        {:ok, command_handle} ->
          provider_session_id = discover_new_session_id(sprite, existing_session_ids)
          {:ok, maybe_put_provider_session_id(command_handle, provider_session_id)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def attach_console(name, session_id, opts) when is_binary(name) and is_binary(session_id) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)
      Sprites.attach_session(sprite, session_id, opts)
    end
  end

  @impl true
  def write_console(command_handle, data), do: Sprites.write(command_handle, data)

  @impl true
  def resize_console(command_handle, rows, cols), do: Sprites.resize(command_handle, rows, cols)

  @impl true
  def close_console(command_handle) do
    Sprites.close_stdin(command_handle)
    :ok
  rescue
    error ->
      {:error, error}
  end

  @impl true
  def await_console(command_handle, timeout), do: Sprites.await(command_handle, timeout)

  @impl true
  def list_sessions(name) when is_binary(name) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)

      case Sprites.list_sessions(sprite) do
        {:ok, sessions} ->
          {:ok, Enum.map(sessions, &session_to_map/1)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def list_checkpoints(name) when is_binary(name) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)

      case Sprites.list_checkpoints(sprite) do
        {:ok, checkpoints} ->
          {:ok, Enum.map(checkpoints, &checkpoint_to_map/1)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def get_checkpoint(name, checkpoint_id)
      when is_binary(name) and is_binary(checkpoint_id) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)

      case Sprites.get_checkpoint(sprite, checkpoint_id) do
        {:ok, checkpoint} ->
          {:ok, checkpoint_to_map(checkpoint)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def create_checkpoint(name, opts) when is_binary(name) and is_list(opts) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)

      case Sprites.create_checkpoint(sprite, opts) do
        {:ok, messages} ->
          {:ok, Enum.map(messages, &Sprites.StreamMessage.to_map/1)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def restore_checkpoint(name, checkpoint_id)
      when is_binary(name) and is_binary(checkpoint_id) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)

      case Sprites.restore_checkpoint(sprite, checkpoint_id) do
        {:ok, messages} ->
          {:ok, Enum.map(messages, &Sprites.StreamMessage.to_map/1)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def get_network_policy(name) when is_binary(name) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)

      case Sprites.get_network_policy(sprite) do
        {:ok, policy} ->
          {:ok, Sprites.Policy.to_map(policy)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def update_network_policy(name, policy) when is_binary(name) and is_map(policy) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)
      normalized_policy = Sprites.Policy.from_map(policy)
      Sprites.update_network_policy(sprite, normalized_policy)
    end
  end

  @impl true
  def get_url_settings(name) when is_binary(name) do
    with {:ok, client} <- client(),
         {:ok, payload} <- Sprites.get_sprite(client, name) do
      url_settings =
        payload
        |> read_value([:url_settings, "url_settings"])
        |> case do
          %{} = settings -> settings
          _ -> %{}
        end

      {:ok,
       %{
         url: read_value(payload, [:url, "url"]),
         auth: read_value(url_settings, [:auth, "auth"]) || "bearer",
         raw: url_settings
       }}
    end
  end

  @impl true
  def update_url_settings(name, settings) when is_binary(name) and is_map(settings) do
    with {:ok, client} <- client() do
      sprite = Sprites.sprite(client, name)
      Sprites.update_url_settings(sprite, settings)
    end
  end

  defp client do
    token = api_token()

    if is_binary(token) and byte_size(token) > 0 do
      {:ok, Sprites.new(token, base_url: base_url())}
    else
      {:error, :sprites_not_configured}
    end
  end

  defp api_token, do: Application.get_env(:fizz, :sprites_api_key)
  defp base_url, do: Application.get_env(:fizz, :sprites_base_url, @default_base_url)

  defp checkpoint_to_map(checkpoint) do
    %{
      id: checkpoint.id,
      create_time: checkpoint.create_time,
      history: checkpoint.history,
      comment: checkpoint.comment
    }
  end

  defp list_session_ids(sprite) do
    case Sprites.list_sessions(sprite) do
      {:ok, sessions} ->
        sessions
        |> Enum.map(& &1.id)
        |> Enum.filter(&is_binary/1)

      _ ->
        []
    end
  end

  defp discover_new_session_id(sprite, previous_session_ids) do
    case Sprites.list_sessions(sprite) do
      {:ok, sessions} ->
        sessions
        |> Enum.map(& &1.id)
        |> Enum.find(fn session_id ->
          is_binary(session_id) and session_id not in previous_session_ids
        end)

      _ ->
        nil
    end
  end

  defp maybe_put_provider_session_id(command_handle, provider_session_id)
       when is_binary(provider_session_id) do
    Map.put(command_handle, :provider_session_id, provider_session_id)
  end

  defp maybe_put_provider_session_id(command_handle, _provider_session_id), do: command_handle

  defp session_to_map(session) do
    %{
      id: session.id,
      command: session.command,
      workdir: session.workdir,
      created: session.created,
      bytes_per_second: session.bytes_per_second,
      is_active: session.is_active,
      last_activity: session.last_activity,
      tty: session.tty
    }
  end

  defp read_value(data, keys) do
    map = if is_map(data), do: data, else: %{}

    Enum.find_value(keys, fn key ->
      Map.get(map, key)
    end)
  end
end
