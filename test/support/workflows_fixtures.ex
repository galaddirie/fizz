defmodule Fizz.WorkflowsFixtures do
  @moduledoc false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts.Scope
  alias Fizz.Workflows

  def project_scope_fixture do
    user = user_fixture()
    organization_scope = organization_scope_fixture(user: user)

    project =
      project_fixture(organization_scope, %{name: "Project #{System.unique_integer([:positive])}"})

    organization_scope
    |> Scope.with_project(project)
    |> Scope.with_project_role(:admin)
  end

  def published_version_fixture(scope, snapshot_attrs \\ valid_snapshot_attrs()) do
    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Workflow #{System.unique_integer([:positive])}",
        description: "Workflow definition"
      })

    {:ok, saved_draft} = Workflows.save_draft(scope, draft, snapshot_attrs)
    {:ok, version} = Workflows.publish_draft(scope, saved_draft)

    %{definition: definition, draft: saved_draft, version: version}
  end

  def valid_snapshot_attrs do
    entry_step = step(%{type_id: "debug", name: "Entry"})
    debug_step = step(%{type_id: "debug", name: "Debug"})

    snapshot_attrs(%{
      steps: [entry_step, debug_step],
      connections: [
        connection(%{source_step_id: entry_step.id, target_step_id: debug_step.id})
      ]
    })
  end

  def long_running_snapshot_attrs(duration_ms \\ 1_000) do
    entry_step = step(%{type_id: "debug", name: "Entry"})

    wait_step =
      step(%{
        type_id: "wait",
        name: "Wait",
        config: %{"duration" => duration_ms, "unit" => "milliseconds"}
      })

    snapshot_attrs(%{
      steps: [entry_step, wait_step],
      connections: [
        connection(%{source_step_id: entry_step.id, target_step_id: wait_step.id})
      ]
    })
  end

  def snapshot_attrs(overrides) do
    Map.merge(
      %{
        steps: [],
        connections: [],
        step_groups: [],
        viewport: %{"x" => 0, "y" => 0, "zoom" => 1.0},
        settings: %{}
      },
      overrides
    )
  end

  def step(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        type_id: "debug",
        name: "Step #{System.unique_integer([:positive])}",
        config: %{},
        position: %{"x" => 100, "y" => 100},
        notes: nil
      },
      attrs
    )
  end

  def connection(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        source_step_id: Ecto.UUID.generate(),
        source_output: "main",
        target_step_id: Ecto.UUID.generate(),
        target_input: "main"
      },
      attrs
    )
  end
end
