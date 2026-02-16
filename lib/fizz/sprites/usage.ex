defmodule Fizz.Sprites.Usage do
  @moduledoc """
  Aggregates and updates workspace daily usage counters.
  """

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Sprites.WorkspaceUsageDaily

  @allowed_fields [
    :jobs_total,
    :jobs_succeeded,
    :jobs_failed,
    :jobs_canceled,
    :exec_seconds,
    :log_bytes,
    :console_seconds,
    :sprites_created,
    :sprites_deleted,
    :quota_rejections,
    :rate_limited
  ]

  @spec increment(String.t(), map()) :: :ok
  def increment(workspace_id, increments) when is_binary(workspace_id) and is_map(increments) do
    usage_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    workspace_uuid = Ecto.UUID.dump!(workspace_id)
    usage_date = Date.utc_today()
    now = DateTime.utc_now()
    deltas = usage_deltas(increments)
    seeds = seed_values(deltas)

    _ =
      Repo.query!(
        """
        INSERT INTO workspace_usage_daily (
          id,
          workspace_id,
          usage_date,
          jobs_total,
          jobs_succeeded,
          jobs_failed,
          jobs_canceled,
          exec_seconds,
          log_bytes,
          console_seconds,
          sprites_created,
          sprites_deleted,
          quota_rejections,
          rate_limited,
          inserted_at,
          updated_at
        )
        VALUES (
          $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16
        )
        ON CONFLICT (workspace_id, usage_date)
        DO UPDATE SET
          jobs_total = GREATEST(workspace_usage_daily.jobs_total + $17, 0),
          jobs_succeeded = GREATEST(workspace_usage_daily.jobs_succeeded + $18, 0),
          jobs_failed = GREATEST(workspace_usage_daily.jobs_failed + $19, 0),
          jobs_canceled = GREATEST(workspace_usage_daily.jobs_canceled + $20, 0),
          exec_seconds = GREATEST(workspace_usage_daily.exec_seconds + $21, 0),
          log_bytes = GREATEST(workspace_usage_daily.log_bytes + $22, 0),
          console_seconds = GREATEST(workspace_usage_daily.console_seconds + $23, 0),
          sprites_created = GREATEST(workspace_usage_daily.sprites_created + $24, 0),
          sprites_deleted = GREATEST(workspace_usage_daily.sprites_deleted + $25, 0),
          quota_rejections = GREATEST(workspace_usage_daily.quota_rejections + $26, 0),
          rate_limited = GREATEST(workspace_usage_daily.rate_limited + $27, 0),
          updated_at = $16
        """,
        [
          usage_id,
          workspace_uuid,
          usage_date,
          Map.fetch!(seeds, :jobs_total),
          Map.fetch!(seeds, :jobs_succeeded),
          Map.fetch!(seeds, :jobs_failed),
          Map.fetch!(seeds, :jobs_canceled),
          Map.fetch!(seeds, :exec_seconds),
          Map.fetch!(seeds, :log_bytes),
          Map.fetch!(seeds, :console_seconds),
          Map.fetch!(seeds, :sprites_created),
          Map.fetch!(seeds, :sprites_deleted),
          Map.fetch!(seeds, :quota_rejections),
          Map.fetch!(seeds, :rate_limited),
          now,
          now,
          Map.fetch!(deltas, :jobs_total),
          Map.fetch!(deltas, :jobs_succeeded),
          Map.fetch!(deltas, :jobs_failed),
          Map.fetch!(deltas, :jobs_canceled),
          Map.fetch!(deltas, :exec_seconds),
          Map.fetch!(deltas, :log_bytes),
          Map.fetch!(deltas, :console_seconds),
          Map.fetch!(deltas, :sprites_created),
          Map.fetch!(deltas, :sprites_deleted),
          Map.fetch!(deltas, :quota_rejections),
          Map.fetch!(deltas, :rate_limited)
        ]
      )

    :ok
  end

  def increment(_workspace_id, _increments), do: :ok

  @spec get(String.t(), keyword()) :: [WorkspaceUsageDaily.t()]
  def get(workspace_id, opts \\ [])

  def get(workspace_id, opts) when is_binary(workspace_id) do
    days = Keyword.get(opts, :days, 30)
    threshold = Date.add(Date.utc_today(), -days + 1)

    from(usage in WorkspaceUsageDaily,
      where: usage.workspace_id == ^workspace_id and usage.usage_date >= ^threshold,
      order_by: [asc: usage.usage_date]
    )
    |> Repo.all()
  end

  def get(_workspace_id, _opts), do: []

  @spec prune_older_than(pos_integer()) :: non_neg_integer()
  def prune_older_than(days) when is_integer(days) and days > 0 do
    threshold = Date.add(Date.utc_today(), -days)

    {count, _} =
      from(usage in WorkspaceUsageDaily, where: usage.usage_date < ^threshold)
      |> Repo.delete_all()

    count
  end

  defp usage_deltas(increments) do
    Enum.reduce(@allowed_fields, %{}, fn field, acc ->
      Map.put(acc, field, normalize_delta(Map.get(increments, field, 0)))
    end)
  end

  defp normalize_delta(value) when is_integer(value), do: value
  defp normalize_delta(_value), do: 0

  defp seed_values(deltas) do
    Enum.reduce(@allowed_fields, %{}, fn field, acc ->
      Map.put(acc, field, max(Map.fetch!(deltas, field), 0))
    end)
  end
end
