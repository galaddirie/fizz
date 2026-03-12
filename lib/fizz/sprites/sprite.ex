defmodule Fizz.Sprites.Sprite do
  @moduledoc """
  project-scoped persistent Sprite descriptor.
  """

  use Fizz.Schema

  alias Fizz.Accounts.{Project, User}
  alias Fizz.Sprites.{Checkpoint, ConsoleSession, ExecJob, Service}

  @statuses [:provisioning, :ready, :error, :deleting, :deleted]
  @url_auth_modes [:default, :public, :bearer]

  schema "sprites" do
    field :name, :string
    field :remote_name, :string
    field :remote_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :provisioning
    field :url, :string
    field :url_auth_mode, Ecto.Enum, values: @url_auth_modes, default: :default
    field :config, :map, default: %{}
    field :metadata, :map, default: %{}
    field :last_seen_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :created_by_user, User

    has_many :exec_jobs, ExecJob
    has_many :console_sessions, ConsoleSession
    has_many :services, Service
    has_many :checkpoints, Checkpoint

    timestamps()
  end

  @doc false
  def changeset(sprite, attrs) do
    sprite
    |> cast(attrs, [
      :project_id,
      :created_by_user_id,
      :name,
      :remote_name,
      :remote_id,
      :status,
      :url,
      :url_auth_mode,
      :config,
      :metadata,
      :last_seen_at,
      :deleted_at
    ])
    |> validate_required([:project_id, :name, :remote_name, :status])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:remote_name, min: 3, max: 120)
    |> validate_format(:name, ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/,
      message: "must contain letters, numbers, underscores, or hyphens"
    )
    |> validate_length(:url, max: 500)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint(:remote_name)
    |> unique_constraint(:name, name: :sprites_project_id_name_index)
  end
end
