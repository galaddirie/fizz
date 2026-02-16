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
    usage_date = Date.utc_today()

    usage =
      Repo.get_by(WorkspaceUsageDaily, workspace_id: workspace_id, usage_date: usage_date) ||
        %WorkspaceUsageDaily{workspace_id: workspace_id, usage_date: usage_date}

    attrs =
      Enum.reduce(
        @allowed_fields,
        %{workspace_id: workspace_id, usage_date: usage_date},
        fn field, acc ->
          current = Map.get(usage, field, 0)
          delta = Map.get(increments, field, 0)
          Map.put(acc, field, max(current + delta, 0))
        end
      )

    usage
    |> WorkspaceUsageDaily.changeset(attrs)
    |> Repo.insert_or_update!()

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
end
