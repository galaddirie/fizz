defmodule Fizz.Integrations.GitCredentialSetup do
  @moduledoc """
  Configures git credentials inside a sprite VM so that `git clone`/`git push`
  work transparently with the user's OAuth token.

  Strategy:
  1. Write `~/.git-credentials` with the token in git-credential-store format.
  2. Run `git config --global` commands to enable the store helper and set the
     user's real identity (name + email from their GitHub profile).

  Uses `Sprites.cmd/4` for git config so the sprite's existing `.gitconfig`
  is preserved (init.defaultBranch, etc.) rather than overwritten.
  """

  alias Fizz.Sprites.Client

  require Logger

  @git_credentials_path "/home/sprite/.git-credentials"

  @doc """
  Writes credential files and configures git inside the sprite.

  ## Options

    * `:user_name` - Git user.name (from GitHub profile)
    * `:user_email` - Git user.email (from GitHub profile)

  Returns `{:ok, env_tuples}` with env vars to pass to the console bash session.
  """
  @spec setup(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def setup(remote_name, access_token, hosts, opts \\ []) do
    user_name = Keyword.get(opts, :user_name)
    user_email = Keyword.get(opts, :user_email)

    with {:ok, remote_sprite} <- Client.sprite(remote_name),
         :ok <- write_git_credentials(remote_sprite, access_token, hosts),
         :ok <- configure_git(remote_sprite, user_name, user_email) do
      env_tuples = [{"GIT_TERMINAL_PROMPT", "0"}]
      {:ok, env_tuples}
    else
      {:error, reason} ->
        Logger.warning("Git credential setup failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Removes credential files from the sprite.
  """
  @spec teardown(String.t()) :: :ok
  def teardown(remote_name) do
    with {:ok, remote_sprite} <- Client.sprite(remote_name) do
      {_, _} = Sprites.cmd(remote_sprite, "rm", ["-f", @git_credentials_path], timeout: 5_000)
      :ok
    else
      _ -> :ok
    end
  end

  # Write ~/.git-credentials in the format git credential-store expects:
  # https://x-access-token:TOKEN@github.com
  #
  # Uses Sprites.cmd with base64 encoding to safely write the file without
  # shell escaping issues. The Sprites Filesystem HTTP API has a URL routing
  # bug (missing /v1/sprites/{name}/ prefix), so we use cmd instead.
  defp write_git_credentials(remote_sprite, access_token, hosts) do
    content =
      hosts
      |> Enum.map_join("\n", fn host ->
        "https://x-access-token:#{access_token}@#{host}"
      end)
      |> Kernel.<>("\n")

    encoded = Base.encode64(content)

    {_output, exit_code} =
      Sprites.cmd(
        remote_sprite,
        "sh",
        ["-c", "echo #{encoded} | base64 -d > #{@git_credentials_path} && chmod 600 #{@git_credentials_path}"],
        timeout: 5_000
      )

    if exit_code == 0, do: :ok, else: {:error, :write_credentials_failed}
  end

  # Use `git config --global` to merge settings into the existing gitconfig
  # rather than overwriting the file (preserves sprite defaults like init.defaultBranch).
  defp configure_git(remote_sprite, user_name, user_email) do
    run_git_config(remote_sprite, "credential.helper", "store")

    if is_binary(user_name) and user_name != "" do
      run_git_config(remote_sprite, "user.name", user_name)
    end

    if is_binary(user_email) and user_email != "" do
      run_git_config(remote_sprite, "user.email", user_email)
    end

    :ok
  end

  defp run_git_config(remote_sprite, key, value) do
    {_output, exit_code} =
      Sprites.cmd(remote_sprite, "git", ["config", "--global", key, value], timeout: 5_000)

    if exit_code != 0 do
      Logger.warning("git config --global #{key} failed with exit code #{exit_code}")
    end

    :ok
  rescue
    error ->
      Logger.warning("git config --global #{key} raised: #{Exception.message(error)}")
      :ok
  end
end
