defmodule Fizz.WorkflowsTest do
  use Fizz.DataCase, async: false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts.Scope
  alias Fizz.Workflows

  test "create definition with initial empty draft" do
    scope = project_scope_fixture()

    assert {:ok, %{definition: definition, draft: draft}} =
             Workflows.create_definition(scope, %{
               name: "Customer Intake",
               description: "Collect and route inbound requests"
             })

    assert definition.project_id == scope.project.id
    assert definition.workos_organization_id == scope.project.workos_organization_id
    assert definition.created_by_user_id == scope.user.id
    assert definition.archived_at == nil

    assert draft.workflow_definition_id == definition.id
    assert draft.version == 1
    assert draft.status == :draft
    assert draft.steps == []
    assert draft.connections == []
    assert draft.step_groups == []
    assert draft.viewport == %{"x" => 0, "y" => 0, "zoom" => 1.0}
    assert draft.settings == %{}
  end

  test "save draft with valid steps and connections" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    entry_step = step(%{type_id: "manual_input", name: "Entry"})
    debug_step = step(%{type_id: "debug", name: "Log"})

    attrs =
      snapshot_attrs(%{
        steps: [entry_step, debug_step],
        connections: [
          connection(%{
            source_step_id: entry_step.id,
            target_step_id: debug_step.id
          })
        ]
      })

    assert {:ok, saved_draft} = Workflows.save_draft(scope, draft, attrs)

    assert Enum.map(saved_draft.steps, & &1.id) == [entry_step.id, debug_step.id]
    assert Enum.map(saved_draft.connections, & &1.id) == [List.first(attrs.connections).id]
    assert saved_draft.step_groups == []
  end

  test "save draft rejects cyclic graphs" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    first_step = step(%{type_id: "debug", name: "First"})
    second_step = step(%{type_id: "debug", name: "Second"})

    attrs =
      snapshot_attrs(%{
        steps: [first_step, second_step],
        connections: [
          connection(%{source_step_id: first_step.id, target_step_id: second_step.id}),
          connection(%{source_step_id: second_step.id, target_step_id: first_step.id})
        ]
      })

    assert {:error, changeset} = Workflows.save_draft(scope, draft, attrs)
    assert_message!(errors_on(changeset).connections, "creates a cycle")
  end

  test "save draft rejects unknown type ids" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    attrs =
      snapshot_attrs(%{
        steps: [step(%{type_id: "missing_step_type", name: "Missing"})]
      })

    assert {:error, changeset} = Workflows.save_draft(scope, draft, attrs)
    assert_message!(errors_on(changeset).steps, "unknown step types")
  end

  test "save draft rejects duplicate step ids" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    duplicate_id = Ecto.UUID.generate()

    attrs =
      snapshot_attrs(%{
        steps: [
          step(%{id: duplicate_id, name: "First"}),
          step(%{id: duplicate_id, name: "Second"})
        ]
      })

    assert {:error, changeset} = Workflows.save_draft(scope, draft, attrs)
    assert_message!(errors_on(changeset).steps, "duplicate step ids")
  end

  test "publish draft stamps published_at and compiled_hash" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, valid_snapshot_attrs())

    assert {:ok, published_version} = Workflows.publish_draft(scope, saved_draft)

    assert published_version.status == :published
    assert %DateTime{} = published_version.published_at
    assert published_version.published_by_user_id == scope.user.id
    assert is_binary(published_version.compiled_hash)
    assert byte_size(published_version.compiled_hash) == 64
  end

  test "publish draft rejects when no entry step exists" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    assert {:error, changeset} = Workflows.publish_draft(scope, draft)
    assert_message!(errors_on(changeset).steps, "at least one entry step")
  end

  test "publish draft rejects invalid step config" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    invalid_http_step =
      step(%{
        type_id: "http_request",
        name: "HTTP Request",
        config: %{}
      })

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, snapshot_attrs(%{steps: [invalid_http_step]}))

    assert {:error, changeset} = Workflows.publish_draft(scope, saved_draft)
    assert_message!(errors_on(changeset).steps, "invalid config")
  end

  test "publish draft rejects unsupported expression filters" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    debug_step =
      step(%{
        type_id: "debug",
        name: "Debug",
        config: %{"label" => "{{ input.name | concat: \"!\" }}"}
      })

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, snapshot_attrs(%{steps: [debug_step]}))

    assert {:error, changeset} = Workflows.publish_draft(scope, saved_draft)
    assert_message!(errors_on(changeset).steps, "unsupported filter `concat`")
  end

  test "publish draft rejects invalid step expression references" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    debug_step =
      step(%{
        type_id: "debug",
        name: "Debug",
        config: %{"label" => "{{ steps.#{Ecto.UUID.generate()}.body }}"}
      })

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, snapshot_attrs(%{steps: [debug_step]}))

    assert {:error, changeset} = Workflows.publish_draft(scope, saved_draft)
    assert_message!(errors_on(changeset).steps, "unknown step reference")
  end

  test "published version is immutable" do
    scope = project_scope_fixture()
    %{draft: draft} = definition_fixture(scope)

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, valid_snapshot_attrs())

    assert {:ok, published_version} = Workflows.publish_draft(scope, saved_draft)

    assert {:error, :not_a_draft} =
             Workflows.save_draft(scope, published_version, valid_snapshot_attrs())
  end

  test "edit after publish clones to new draft" do
    scope = project_scope_fixture()
    %{definition: definition, draft: draft} = definition_fixture(scope)

    assert {:ok, saved_draft} =
             Workflows.save_draft(scope, draft, valid_snapshot_attrs())

    assert {:ok, published_version} = Workflows.publish_draft(scope, saved_draft)
    assert {:ok, cloned_draft} = Workflows.edit_definition(scope, definition)

    assert cloned_draft.id != published_version.id
    assert cloned_draft.version == 2
    assert cloned_draft.status == :draft
    assert Enum.map(cloned_draft.steps, & &1.id) == Enum.map(published_version.steps, & &1.id)

    assert Enum.map(cloned_draft.connections, & &1.id) ==
             Enum.map(published_version.connections, & &1.id)

    assert cloned_draft.compiled_hash == nil
    assert cloned_draft.published_at == nil
    assert cloned_draft.published_by_user_id == nil
  end

  test "archive hides from list queries" do
    scope = project_scope_fixture()
    %{definition: definition} = definition_fixture(scope)

    assert {:ok, [listed_definition]} = Workflows.list_definitions(scope)
    assert listed_definition.id == definition.id

    assert {:ok, archived_definition} = Workflows.archive_definition(scope, definition)
    assert %DateTime{} = archived_definition.archived_at
    assert {:ok, []} = Workflows.list_definitions(scope)
  end

  defp definition_fixture(scope) do
    {:ok, %{definition: definition, draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Workflow #{System.unique_integer([:positive])}",
        description: "Draft definition"
      })

    %{definition: definition, draft: draft}
  end

  defp project_scope_fixture do
    user = user_fixture()
    organization_scope = organization_scope_fixture(user: user)

    project =
      project_fixture(organization_scope, %{name: "Project #{System.unique_integer([:positive])}"})

    organization_scope
    |> Scope.with_project(project)
    |> Scope.with_project_role(:admin)
  end

  defp valid_snapshot_attrs do
    entry_step = step(%{type_id: "manual_input", name: "Entry"})
    debug_step = step(%{type_id: "debug", name: "Debug"})

    snapshot_attrs(%{
      steps: [entry_step, debug_step],
      connections: [
        connection(%{source_step_id: entry_step.id, target_step_id: debug_step.id})
      ]
    })
  end

  defp snapshot_attrs(overrides) do
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

  defp step(attrs) do
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

  defp connection(attrs) do
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

  defp assert_message!(messages, expected_substring) do
    assert Enum.any?(messages, &String.contains?(&1, expected_substring))
  end
end
