defmodule Fizz.Workflows.Runtime.ContextBuilderTest do
  use Fizz.DataCase, async: true

  alias Fizz.AccountsFixtures
  alias Fizz.Workflows.Runtime.ContextBuilder
  alias Runic.Workflow

  test "exposes slot resolver through Runic global context" do
    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.organization_scope_fixture(user: user)

    run_attrs = %{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      workflow_definition_id: Ecto.UUID.generate(),
      workflow_definition_version_id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      workos_organization_id: scope.organization_id,
      compiled_hash: "compiled"
    }

    context = ContextBuilder.build_run_context(scope, run_attrs)

    assert is_function(context._slot_resolver, 4)
    assert is_function(context._global._slot_resolver, 4)
    assert context.user_id == user.id
    assert context.project_id == run_attrs.project_id
    assert context.workos_organization_id == scope.organization_id

    workflow =
      Workflow.new(name: "context-test")
      |> Workflow.put_run_context(context)

    run_context = Workflow.get_run_context(workflow, "any-step")

    assert is_function(run_context._slot_resolver, 4)
    assert run_context.workflow == context.workflow
    assert run_context.user_id == user.id
  end
end
