defmodule Fizz.Workflows.Runtime.DurableRows do
  @moduledoc false

  import Ecto.Query

  alias Fizz.Repo

  def claim_many(query, changeset_fun, claim_status, opts) when is_function(changeset_fun, 2) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 50)
    claimed_by = Keyword.get(opts, :claimed_by, owner_node())

    Repo.transaction(fn ->
      query
      |> limit(^limit)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> Repo.all()
      |> Enum.map(&claim_row!(&1, changeset_fun, claim_status, now, claimed_by))
    end)
  end

  def claim_one(schema, row_id, changeset_fun, claim_status, lock_mode, opts)
      when is_binary(row_id) and is_function(changeset_fun, 2) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    claimed_by = Keyword.get(opts, :claimed_by, owner_node())

    Repo.transaction(fn ->
      schema
      |> where([row], row.id == ^row_id and row.status == :pending)
      |> apply_lock(lock_mode)
      |> Repo.one()
      |> case do
        nil -> Repo.rollback(:not_found)
        row -> claim_row!(row, changeset_fun, claim_status, now, claimed_by)
      end
    end)
  end

  def recover_stale(schema, claim_status, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    claim_ttl_ms = Keyword.get(opts, :claim_ttl_ms, 30_000)
    cutoff = DateTime.add(now, -claim_ttl_ms, :millisecond)

    {count, _rows} =
      schema
      |> where([row], row.status == ^claim_status and row.claimed_at < ^cutoff)
      |> Repo.update_all(
        set: [status: :pending, claimed_at: nil, claimed_by: nil, updated_at: now]
      )

    {:ok, count}
  end

  def release_claim(schema, row_id, claim_status) when is_binary(row_id) do
    update_matching(schema, row_id, [claim_status],
      status: :pending,
      claimed_at: nil,
      claimed_by: nil
    )
  end

  def get(schema, row_id) when is_binary(row_id) do
    case Repo.get(schema, row_id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def update_matching(schema, row_id, from_statuses, set_attrs) when is_binary(row_id) do
    set_attrs = Keyword.put_new(set_attrs, :updated_at, DateTime.utc_now())

    {count, _rows} =
      schema
      |> where([row], row.id == ^row_id and row.status in ^from_statuses)
      |> Repo.update_all(set: set_attrs)

    case count do
      1 -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp claim_row!(row, changeset_fun, claim_status, now, claimed_by) do
    changeset_fun.(row, %{status: claim_status, claimed_at: now, claimed_by: claimed_by})
    |> Repo.update!()
  end

  defp apply_lock(query, :for_update), do: lock(query, "FOR UPDATE")
  defp apply_lock(query, :for_update_skip_locked), do: lock(query, "FOR UPDATE SKIP LOCKED")

  defp owner_node, do: Atom.to_string(node())
end
