defmodule Fizz.Workflows.Store.Options do
  @moduledoc false

  alias Fizz.Repo

  def for_run(run, fence_token, opts \\ []) do
    Keyword.merge(
      [
        org_id: run.workos_organization_id,
        project_id: run.project_id,
        fence_token: fence_token,
        repo: Repo
      ],
      Keyword.get(opts, :store_opts, [])
    )
  end
end
