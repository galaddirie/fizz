defmodule Fizz.Sprites.RateLimiter do
  @moduledoc """
  Database-backed minute window rate limiting per workspace.
  """

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Sprites.RateLimitWindow

  @spec check_and_increment(String.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def check_and_increment(workspace_id, bucket, limit, window_seconds \\ 60)

  def check_and_increment(workspace_id, bucket, limit, window_seconds)
      when is_binary(workspace_id) and is_binary(bucket) and is_integer(limit) and limit > 0 and
             is_integer(window_seconds) and window_seconds > 0 do
    now = DateTime.utc_now()

    unix_window_start =
      now
      |> DateTime.to_unix(:second)
      |> then(&(&1 - rem(&1, window_seconds)))

    window_start = DateTime.from_unix!(unix_window_start * 1_000_000, :microsecond)

    {_updated_count, rows} =
      Repo.insert_all(
        RateLimitWindow,
        [
          %{
            workspace_id: workspace_id,
            bucket: bucket,
            window_start: window_start,
            count: 1,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: [inc: [count: 1], set: [updated_at: now]],
        conflict_target: [:workspace_id, :bucket, :window_start],
        returning: [:count]
      )

    case rows do
      [%{count: count}] when count <= limit -> :ok
      [%{count: _count}] -> {:error, :rate_limited}
      _ -> {:error, :rate_limited}
    end
  end

  def check_and_increment(_workspace_id, _bucket, _limit, _window_seconds),
    do: {:error, :rate_limited}

  @spec prune_older_than(pos_integer()) :: non_neg_integer()
  def prune_older_than(days) when is_integer(days) and days > 0 do
    threshold = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    {count, _} =
      from(window in RateLimitWindow, where: window.window_start < ^threshold)
      |> Repo.delete_all()

    count
  end
end
