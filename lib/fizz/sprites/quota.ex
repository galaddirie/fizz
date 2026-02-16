defmodule Fizz.Sprites.Quota do
  @moduledoc """
  Quota checks and workspace limit persistence.
  """

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Sprites.{Client, ConsoleSession, ExecJob, Service, Sprite, WorkspaceSpriteLimit}

  @type quota_name ::
          :sprites
          | :concurrent_jobs
          | :jobs_per_minute
          | :console_sessions
          | :services_per_sprite
          | :checkpoints_per_sprite

  @spec get_limits(String.t()) :: WorkspaceSpriteLimit.t() | nil
  def get_limits(workspace_id) when is_binary(workspace_id) do
    Repo.get_by(WorkspaceSpriteLimit, workspace_id: workspace_id)
  end

  def get_limits(_workspace_id), do: nil

  @spec ensure_limits(String.t()) :: WorkspaceSpriteLimit.t() | nil
  def ensure_limits(workspace_id) when is_binary(workspace_id) do
    get_limits(workspace_id) ||
      create_default_limits(workspace_id)
  end

  def ensure_limits(_workspace_id), do: nil

  @spec update_limits(String.t(), map()) ::
          {:ok, WorkspaceSpriteLimit.t()} | {:error, Ecto.Changeset.t()}
  def update_limits(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    limits = ensure_limits(workspace_id) || %WorkspaceSpriteLimit{workspace_id: workspace_id}

    limits
    |> WorkspaceSpriteLimit.changeset(Map.put(attrs, :workspace_id, workspace_id))
    |> Repo.insert_or_update()
  end

  @spec check(String.t(), quota_name(), keyword()) ::
          :ok | {:error, {:quota_exceeded, quota_name()}}
  def check(workspace_id, quota, opts \\ []) when is_binary(workspace_id) do
    limits = ensure_limits(workspace_id)

    case {quota, limits} do
      {:sprites, %WorkspaceSpriteLimit{max_sprites: max_sprites}} ->
        count =
          from(sprite in Sprite,
            where: sprite.workspace_id == ^workspace_id and sprite.status != :deleted
          )
          |> Repo.aggregate(:count)

        if count < max_sprites, do: :ok, else: {:error, {:quota_exceeded, :sprites}}

      {:concurrent_jobs, %WorkspaceSpriteLimit{max_concurrent_jobs: max_jobs}} ->
        count =
          from(job in ExecJob,
            where: job.workspace_id == ^workspace_id and job.state in [:queued, :running]
          )
          |> Repo.aggregate(:count)

        if count < max_jobs, do: :ok, else: {:error, {:quota_exceeded, :concurrent_jobs}}

      {:console_sessions, %WorkspaceSpriteLimit{max_console_sessions: max_sessions}} ->
        count =
          from(session in ConsoleSession,
            where: session.workspace_id == ^workspace_id and session.state == :active
          )
          |> Repo.aggregate(:count)

        if count < max_sessions, do: :ok, else: {:error, {:quota_exceeded, :console_sessions}}

      {:services_per_sprite, %WorkspaceSpriteLimit{max_services_per_sprite: max_services}} ->
        sprite_id = Keyword.fetch!(opts, :sprite_id)

        count =
          from(service in Service,
            where: service.workspace_id == ^workspace_id and service.sprite_id == ^sprite_id
          )
          |> Repo.aggregate(:count)

        if count < max_services,
          do: :ok,
          else: {:error, {:quota_exceeded, :services_per_sprite}}

      {:checkpoints_per_sprite,
       %WorkspaceSpriteLimit{max_checkpoints_per_sprite: max_checkpoints}} ->
        current = Keyword.get(opts, :current_count, 0)

        if current < max_checkpoints,
          do: :ok,
          else: {:error, {:quota_exceeded, :checkpoints_per_sprite}}

      _ ->
        :ok
    end
  end

  defp create_default_limits(workspace_id) do
    defaults = Client.default_limits()

    %WorkspaceSpriteLimit{}
    |> WorkspaceSpriteLimit.changeset(Map.put(defaults, :workspace_id, workspace_id))
    |> Repo.insert!()
  end
end
