defmodule Fizz.Workflows.Store.Paths do
  @moduledoc false

  @spec db_path(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def db_path(data_dir, run_id, org_id, project_id) do
    Path.join(data_dir, relative_db_path(run_id, org_id, project_id))
  end

  @spec relative_db_path(String.t(), String.t(), String.t()) :: String.t()
  def relative_db_path(run_id, org_id, project_id) do
    {prefix_one, prefix_two} = hash_prefixes(run_id)

    Path.join([org_id, project_id, prefix_one, prefix_two, "#{run_id}.sqlite"])
  end

  @spec replica_url(String.t(), keyword()) :: String.t()
  def replica_url(run_id, opts) do
    bucket = Keyword.fetch!(opts, :s3_bucket)
    prefix = Keyword.get(opts, :s3_prefix, "workflows")
    org_id = Keyword.fetch!(opts, :org_id)
    project_id = Keyword.fetch!(opts, :project_id)

    relative_path =
      [prefix, relative_db_path(run_id, org_id, project_id)]
      |> Path.join()
      |> String.replace("\\", "/")

    "s3://#{bucket}/#{relative_path}"
  end

  @spec hash_prefixes(String.t()) :: {String.t(), String.t()}
  def hash_prefixes(run_id) do
    digest =
      :crypto.hash(:sha256, run_id)
      |> Base.encode16(case: :lower)

    {String.slice(digest, 0, 2), String.slice(digest, 2, 2)}
  end
end
