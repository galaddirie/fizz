defmodule Fizz.Sprites.SpriteConsoleChunk do
  use Fizz.Schema

  alias Fizz.Sprites.SpriteSession

  @streams ~w(stdout stderr)

  schema "sprite_console_chunks" do
    belongs_to :sprite_session, SpriteSession

    field :seq, :integer
    field :stream, :string
    field :data, :string

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:sprite_session_id, :seq, :stream, :data])
    |> validate_required([:sprite_session_id, :seq, :stream, :data])
    |> validate_inclusion(:stream, @streams)
    |> validate_number(:seq, greater_than: 0)
    |> foreign_key_constraint(:sprite_session_id)
    |> unique_constraint([:sprite_session_id, :seq], name: :sprite_console_chunks_session_seq_idx)
  end
end
