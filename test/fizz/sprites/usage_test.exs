defmodule Fizz.Sprites.UsageTest do
  use Fizz.DataCase, async: true

  import Ecto.Query
  import Fizz.AccountsFixtures

  alias Fizz.Repo
  alias Fizz.Sprites.{Usage, WorkspaceUsageDaily}

  setup do
    scope = organization_scope_fixture()
    workspace = workspace_fixture(scope)

    %{workspace: workspace}
  end

  test "upserts daily usage and applies delta updates", %{workspace: workspace} do
    Usage.increment(workspace.id, %{jobs_total: 3, log_bytes: 10, sprites_created: 1})
    Usage.increment(workspace.id, %{jobs_total: -1, log_bytes: 5, sprites_created: 2})
    Usage.increment(workspace.id, %{jobs_total: -10})

    assert 1 =
             from(usage in WorkspaceUsageDaily,
               where:
                 usage.workspace_id == ^workspace.id and
                   usage.usage_date == ^Date.utc_today(),
               select: count(usage.id)
             )
             |> Repo.one()

    usage =
      Repo.get_by(WorkspaceUsageDaily,
        workspace_id: workspace.id,
        usage_date: Date.utc_today()
      )

    assert usage.jobs_total == 0
    assert usage.log_bytes == 15
    assert usage.sprites_created == 3
  end
end
