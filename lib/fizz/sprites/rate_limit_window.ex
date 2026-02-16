defmodule Fizz.Sprites.RateLimitWindow do
  @moduledoc """
  DB-backed workspace rate limiter window.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Workspace

  schema "workspace_rate_limit_windows" do
    field :bucket, :string
    field :window_start, :utc_datetime_usec
    field :count, :integer, default: 0

    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc false
  def changeset(window, attrs) do
    window
    |> cast(attrs, [:workspace_id, :bucket, :window_start, :count])
    |> validate_required([:workspace_id, :bucket, :window_start, :count])
    |> validate_number(:count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:window_start,
      name: :workspace_rate_limit_windows_ws_bucket_window_idx
    )
  end
end
