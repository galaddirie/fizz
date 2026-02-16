defmodule Fizz.Sprites.ExecLogChunk do
  @moduledoc """
  Incremental persisted output chunk for a job execution stream.
  """

  use Fizz.Schema

  alias Fizz.Sprites.ExecJob

  @streams [:stdout, :stderr, :system]

  schema "sprite_exec_log_chunks" do
    field :seq, :integer
    field :stream, Ecto.Enum, values: @streams
    field :chunk, :binary
    field :byte_size, :integer

    belongs_to :job, ExecJob, foreign_key: :job_id

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(log_chunk, attrs) do
    log_chunk
    |> cast(attrs, [:job_id, :seq, :stream, :chunk, :byte_size])
    |> validate_required([:job_id, :seq, :stream, :chunk, :byte_size])
    |> validate_number(:seq, greater_than_or_equal_to: 0)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:job_id)
    |> unique_constraint(:seq, name: :sprite_exec_log_chunks_job_id_seq_index)
  end
end
