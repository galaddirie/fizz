defmodule Fizz.Sprites.RateLimiterTest do
  use Fizz.DataCase, async: true

  import Ecto.Query
  import Fizz.AccountsFixtures

  alias Fizz.Repo
  alias Fizz.Sprites.{RateLimiter, RateLimitWindow}

  setup do
    scope = organization_scope_fixture()
    workspace = workspace_fixture(scope)

    %{workspace: workspace}
  end

  test "increments count in-place and enforces limit", %{workspace: workspace} do
    bucket = "jobs_per_minute"

    assert :ok = RateLimiter.check_and_increment(workspace.id, bucket, 2, 3_600)
    assert :ok = RateLimiter.check_and_increment(workspace.id, bucket, 2, 3_600)

    assert {:error, :rate_limited} =
             RateLimiter.check_and_increment(workspace.id, bucket, 2, 3_600)

    assert 1 =
             from(window in RateLimitWindow,
               where: window.workspace_id == ^workspace.id and window.bucket == ^bucket,
               select: count(window.id)
             )
             |> Repo.one()

    window =
      from(window in RateLimitWindow,
        where: window.workspace_id == ^workspace.id and window.bucket == ^bucket,
        order_by: [desc: window.window_start],
        limit: 1
      )
      |> Repo.one()

    assert window.count == 3
  end
end
