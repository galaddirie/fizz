defmodule Fizz.Workspaces.ExecJob do
  @moduledoc """
  Non-interactive command execution request tracked through Oban.
  """

  use Fizz.Schema

  alias Fizz.Accounts.{Project, User}
  alias Fizz.Workspaces.{ExecLogChunk, Workspace}

  @states [:queued, :running, :succeeded, :failed, :timed_out, :canceled, :system_error]

  schema "workspace_exec_jobs" do
    field :state, Ecto.Enum, values: @states, default: :queued
    field :command, :string
    field :args, {:array, :string}, default: []
    field :env, :map, default: %{}
    field :dir, :string
    field :tty, :boolean, default: false
    field :timeout_ms, :integer
    field :exit_code, :integer
    field :remote_session_id, :string
    field :bytes_stdout, :integer, default: 0
    field :bytes_stderr, :integer, default: 0
    field :bytes_total, :integer, default: 0
    field :error_code, :string
    field :error_message, :string
    field :heartbeat_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :cancel_requested_at, :utc_datetime_usec
    field :oban_job_id, :integer

    belongs_to :workspace, Workspace
    belongs_to :project, Project
    belongs_to :requested_by_user, User

    has_many :log_chunks, ExecLogChunk, foreign_key: :job_id

    timestamps()
  end

  @doc false
  def changeset(exec_job, attrs) do
    exec_job
    |> cast(attrs, [
      :workspace_id,
      :project_id,
      :requested_by_user_id,
      :state,
      :command,
      :args,
      :env,
      :dir,
      :tty,
      :timeout_ms,
      :exit_code,
      :remote_session_id,
      :bytes_stdout,
      :bytes_stderr,
      :bytes_total,
      :error_code,
      :error_message,
      :heartbeat_at,
      :started_at,
      :finished_at,
      :cancel_requested_at,
      :oban_job_id
    ])
    |> validate_required([:workspace_id, :project_id, :command])
    |> validate_length(:command, min: 1, max: 200)
    |> validate_number(:timeout_ms, greater_than: 0)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:requested_by_user_id)
  end
end
