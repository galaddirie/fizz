defmodule Fizz.Sprites.Client do
  @moduledoc """
  Runtime configuration and client helpers for Sprites API access.
  """

  @default_base_url "https://api.sprites.dev"

  @spec client() :: {:ok, Sprites.Client.t()} | {:error, :sprites_not_configured}
  def client do
    case api_key() do
      nil -> {:error, :sprites_not_configured}
      token -> {:ok, Sprites.new(token, base_url: base_url())}
    end
  end

  @spec sprite(String.t()) :: {:ok, Sprites.Sprite.t()} | {:error, :sprites_not_configured}
  def sprite(remote_name) when is_binary(remote_name) do
    with {:ok, client} <- client() do
      {:ok, Sprites.sprite(client, remote_name)}
    end
  end

  @spec base_url() :: String.t()
  def base_url do
    Application.get_env(:fizz, :sprites_api_base_url, @default_base_url)
  end

  @spec api_key() :: String.t() | nil
  def api_key do
    Application.get_env(:fizz, :sprites_api_key)
  end

  @spec default_limits() :: map()
  def default_limits do
    Application.get_env(:fizz, :sprites_limits_defaults, %{
      max_sprites: 20,
      max_concurrent_jobs: 5,
      max_jobs_per_minute: 30,
      max_console_sessions: 2,
      max_services_per_sprite: 10,
      max_checkpoints_per_sprite: 50,
      daily_exec_seconds_limit: 36_000,
      daily_log_bytes_limit: 2_147_483_648
    })
  end

  @spec exec_timeout_ms_default() :: pos_integer()
  def exec_timeout_ms_default do
    Application.get_env(:fizz, :sprites_exec_timeout_ms_default, 30_000)
  end

  @spec log_retention_days() :: pos_integer()
  def log_retention_days do
    Application.get_env(:fizz, :sprites_log_retention_days, 14)
  end

  @spec checkpoint_retention_days() :: pos_integer()
  def checkpoint_retention_days do
    Application.get_env(:fizz, :sprites_checkpoint_retention_days, 14)
  end

  @spec service_log_tail_lines() :: pos_integer()
  def service_log_tail_lines do
    Application.get_env(:fizz, :sprites_service_log_tail_lines, 200)
  end
end
