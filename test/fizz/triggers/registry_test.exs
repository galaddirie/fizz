defmodule Fizz.Triggers.RegistryTest do
  use Fizz.DataCase, async: false

  import Fizz.WorkflowsFixtures

  alias Fizz.Repo
  alias Fizz.Triggers.Registry
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Workflows

  setup do
    scope = project_scope_fixture()
    %{definition: definition, draft: draft} = create_definition_fixture(scope)

    first =
      insert_registration(scope, definition, draft, %{
        step_id: "manual-root",
        kind: "manual"
      })

    second =
      insert_registration(scope, definition, draft, %{
        step_id: "webhook-root",
        kind: "webhook",
        webhook_path: "wh_#{System.unique_integer([:positive])}",
        webhook_secret: "secret"
      })

    third =
      insert_registration(scope, definition, draft, %{
        step_id: "schedule-root",
        kind: "schedule"
      })

    pid =
      start_supervised!({Registry, notifications?: false, refresh_interval_ms: :timer.hours(1)})

    :ok = Registry.refresh()

    %{scope: scope, registrations: [first, second, third], registry_pid: pid}
  end

  test "registry loads registrations into ETS on init", %{scope: scope, registrations: regs} do
    cached = Registry.list_by_project(scope.project.id)

    assert Enum.sort(Enum.map(cached, & &1.id)) == Enum.sort(Enum.map(regs, & &1.id))
  end

  test "get_by_webhook_path returns matching registration", %{registrations: regs} do
    registration = Enum.find(regs, &(&1.kind == "webhook"))

    assert {:ok, cached} = Registry.get_by_webhook_path(registration.webhook_path)
    assert cached.id == registration.id
  end

  test "get_by_webhook_path returns error for unknown path" do
    assert :error = Registry.get_by_webhook_path("missing")
  end

  test "list_by_kind filters by project and kind", %{scope: scope, registrations: regs} do
    expected_ids =
      regs
      |> Enum.filter(&(&1.kind == "schedule"))
      |> Enum.map(& &1.id)

    cached_ids =
      scope.project.id
      |> Registry.list_by_kind(:schedule)
      |> Enum.map(& &1.id)

    assert cached_ids == expected_ids
  end

  defp create_definition_fixture(scope) do
    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Registry #{System.unique_integer([:positive])}",
        description: "Registry test"
      })

    %{definition: definition, draft: draft}
  end

  defp insert_registration(scope, definition, draft, overrides) do
    attrs =
      Map.merge(
        %{
          workflow_definition_id: definition.id,
          definition_version_id: draft.id,
          step_id: "step-#{System.unique_integer([:positive])}",
          project_id: scope.project.id,
          workos_organization_id: scope.project.workos_organization_id,
          kind: "manual",
          status: "active",
          registration_params: %{},
          config_digest: "digest-#{System.unique_integer([:positive])}"
        },
        overrides
      )

    %TriggerRegistration{}
    |> TriggerRegistration.changeset(attrs)
    |> Repo.insert!()
  end
end
