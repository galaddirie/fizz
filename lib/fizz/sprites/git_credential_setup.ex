defmodule Fizz.Sprites.GitCredentialSetup do
  @moduledoc """
  Configures git credentials inside a sprite VM so that `git clone`/`git push`
  work transparently with the user's OAuth token.

  Strategy:
  1. Write `~/.git-credentials` via the Sprites HTTP filesystem API.
  2. Return env tuples that configure git via `GIT_CONFIG_*` environment
     variables (Git 2.31+) — credential.helper, user.name, user.email.

  This avoids `Sprites.cmd/4` entirely (see sprites-sdk#6 — cmd fails with
  `:closed` due to a WebSocket exit-frame race condition). The filesystem
  HTTP API is reliable and the env-var approach preserves the sprite's
  existing `.gitconfig` (init.defaultBranch, etc.).
  """

  alias Fizz.Sprites.Client

  require Logger

  @github_host "github.com"
  @git_credentials_path "/home/sprite/.git-credentials"

  @doc """
  Writes the credential file and returns env tuples for git configuration.

  ## Options

    * `:user_name` - Git user.name (from GitHub profile)
    * `:user_email` - Git user.email (from GitHub profile)

  Returns `{:ok, env_tuples}` with env vars to pass to the console/job session.
  The env tuples configure git via `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_N`/`GIT_CONFIG_VALUE_N`
  so no `git config` commands need to be run inside the sprite.
  """
  @spec setup(String.t(), String.t(), keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def setup(remote_name, access_token, opts \\ []) do
    with {:ok, remote_sprite} <- Client.sprite(remote_name),
         :ok <- write_git_credentials(remote_sprite, access_token) do
      {:ok, build_env_tuples(opts)}
    end
  rescue
    exception ->
      Logger.warning("Git credential setup raised: #{Exception.message(exception)}")
      {:error, {:git_credential_setup_failed, exception}}
  end

  @doc """
  Removes credential files from the sprite.
  """
  @spec teardown(String.t()) :: :ok
  def teardown(remote_name) do
    with {:ok, remote_sprite} <- Client.sprite(remote_name) do
      delete_url =
        fs_url(remote_sprite, "/fs/delete", path: @git_credentials_path, recursive: "false")

      Req.delete(remote_sprite.client.req, url: delete_url)
      :ok
    else
      _ -> :ok
    end
  end

  # Write ~/.git-credentials via the Sprites HTTP filesystem API.
  # Uses the correct /v1/sprites/{name}/fs/write URL prefix.
  defp write_git_credentials(remote_sprite, access_token) do
    content = "https://x-access-token:#{access_token}@#{@github_host}\n"

    url =
      fs_url(remote_sprite, "/fs/write",
        path: @git_credentials_path,
        mode: "600",
        mkdirParents: "true"
      )

    case Req.put(remote_sprite.client.req, url: url, body: content) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Failed to write git credentials: HTTP #{status}")
        {:error, {:write_credentials_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Build env tuples using Git's GIT_CONFIG_* env vars (Git 2.31+).
  # This configures git without needing to run commands in the sprite.
  defp build_env_tuples(opts) do
    user_name = Keyword.get(opts, :user_name)
    user_email = Keyword.get(opts, :user_email)

    config_entries = [{"credential.helper", "store"}]

    config_entries =
      if is_binary(user_name) and user_name != "" do
        config_entries ++ [{"user.name", user_name}]
      else
        config_entries
      end

    config_entries =
      if is_binary(user_email) and user_email != "" do
        config_entries ++ [{"user.email", user_email}]
      else
        config_entries
      end

    git_config_env =
      config_entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {{key, value}, i} ->
        [
          {"GIT_CONFIG_KEY_#{i}", key},
          {"GIT_CONFIG_VALUE_#{i}", value}
        ]
      end)

    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_COUNT", Integer.to_string(length(config_entries))}
      | git_config_env
    ]
  end

  # Build the correct filesystem API URL with the /v1/sprites/{name}/ prefix.
  # The SDK's Sprites.Filesystem module omits this prefix (sprites-sdk routing bug).
  defp fs_url(remote_sprite, endpoint, params) do
    name = URI.encode(remote_sprite.name)
    query = URI.encode_query(params)
    "/v1/sprites/#{name}#{endpoint}?#{query}"
  end
end
