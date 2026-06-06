defmodule Fizz.Triggers.TriggerSourceTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Triggers
  alias Fizz.Triggers.{SourcePoller, TriggerSource}

  test "upsert_source creates and preserves runtime cursor on later syncs" do
    scope = project_scope_fixture()

    attrs = source_attrs(scope, "google:sheet:1")

    assert {:ok, source} =
             Triggers.upsert_source(Map.put(attrs, :cursor, %{"initialized" => false}))

    assert source.cursor == %{"initialized" => false}

    assert {:ok, updated} =
             Triggers.upsert_source(Map.put(attrs, :cursor, %{"initialized" => true}))

    assert updated.id == source.id
    assert updated.cursor == %{"initialized" => false}
  end

  test "claim_source_for_poll enforces a durable lease" do
    scope = project_scope_fixture()
    now = DateTime.utc_now()

    assert {:ok, source} = Triggers.upsert_source(source_attrs(scope, "google:sheet:lease"))

    assert :ok = Triggers.claim_source_for_poll(source.id, "owner-a", 60_000, now)
    assert {:error, :busy} = Triggers.claim_source_for_poll(source.id, "owner-b", 60_000, now)

    later = DateTime.add(now, 61, :second)
    assert :ok = Triggers.claim_source_for_poll(source.id, "owner-b", 60_000, later)
  end

  test "record_source_poll_error stores bounded messages and clears leases" do
    scope = project_scope_fixture()
    now = DateTime.utc_now()

    assert {:ok, source} = Triggers.upsert_source(source_attrs(scope, "google:sheet:error"))
    assert :ok = Triggers.claim_source_for_poll(source.id, "owner-a", 60_000, now)

    source = Repo.get!(TriggerSource, source.id)
    assert source.lease_owner == "owner-a"

    reason = %{status: 403, body: %{"error" => String.duplicate("permission denied ", 100)}}

    assert {:ok, updated} = Triggers.record_source_poll_error(source, reason)

    assert updated.lease_owner == nil
    assert updated.lease_expires_at == nil
    assert updated.consecutive_errors == 1
    assert String.length(updated.error_message) <= 255
    assert updated.error_message =~ "permission denied"
  end

  test "source poller records raised polling errors and releases lease" do
    scope = project_scope_fixture()
    Process.register(self(), Fizz.Triggers.RaisingSourceTest)

    attrs =
      scope
      |> source_attrs("test:raising-source")
      |> Map.merge(%{
        source_module: "Fizz.Triggers.RaisingSource",
        next_poll_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })

    assert {:ok, source} = Triggers.upsert_source(attrs)

    start_supervised!({Registry, keys: :unique, name: Fizz.Triggers.SourceRegistry})

    pid =
      start_supervised!(
        {SourcePoller,
         source_id: source.id, lease_owner: "test-owner", lease_ttl_ms: :timer.minutes(5)}
      )

    send(pid, :poll)
    assert_receive {:raising_source_polled, ^pid}

    updated = wait_for_source(source.id, &is_nil(&1.lease_owner))
    assert updated.lease_owner == nil
    assert updated.lease_expires_at == nil
    assert updated.consecutive_errors == 1
    assert updated.error_message =~ "raising source poll failed"
  end

  defp source_attrs(scope, source_key) do
    %{
      project_id: scope.project.id,
      workos_organization_id: scope.organization_id,
      user_id: scope.user.id,
      kind: "polling",
      provider: "google_oauth",
      source_module: "Fizz.Integrations.Library.Google.Sheets.Triggers.RowChange",
      source_key: source_key,
      status: "active",
      params: %{"spreadsheet_id" => "spreadsheet_1", "sheet_name" => "Sheet1"},
      poll_interval_ms: 60_000,
      next_poll_at: DateTime.utc_now()
    }
  end

  defp wait_for_source(source_id, predicate, attempts \\ 25)

  defp wait_for_source(source_id, predicate, attempts) when attempts > 0 do
    source = Repo.get!(TriggerSource, source_id)

    if predicate.(source) do
      source
    else
      ref = make_ref()
      Process.send_after(self(), {:retry_source, ref}, 10)
      assert_receive {:retry_source, ^ref}
      wait_for_source(source_id, predicate, attempts - 1)
    end
  end

  defp wait_for_source(source_id, _predicate, 0), do: Repo.get!(TriggerSource, source_id)
end
