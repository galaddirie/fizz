defmodule Fizz.Workflows.Compiler.AssemblerContextTest do
  use ExUnit.Case, async: true

  alias Fizz.Accounts.Scope
  alias Fizz.Workflows.Compiler.RuntimeCallbacks

  test "executor context carries runtime identity and scope values" do
    scope = %Scope{user: %{id: "user_123"}, organization_id: "org_123"}

    resolver = fn _requirement_key, _step_id, _provider, _auth_type ->
      {:ok, %{"id" => "credential_123"}}
    end

    resolution_context =
      RuntimeCallbacks.resolution_context(
        %{"input" => true},
        %{
          workflow: %{
            user_id: "user_123",
            project_id: "project_123",
            workos_organization_id: "org_123"
          },
          metadata: %{
            user_id: "user_123",
            project_id: "project_123",
            workos_organization_id: "org_123"
          },
          current_scope: scope,
          scope: scope,
          env: %{"mode" => "test"},
          _credential_resolver: resolver
        },
        %{step_ids: MapSet.new()}
      )

    context =
      RuntimeCallbacks.executor_context(
        %{"input" => true},
        resolution_context,
        %{step_id: "step_123", step_name: "Step", type_id: "debug"}
      )

    assert context.current_scope == scope
    assert context.scope == scope
    assert context.user_id == "user_123"
    assert context.project_id == "project_123"
    assert context.workos_organization_id == "org_123"
    assert context.workflow.project_id == "project_123"
    assert context.metadata.user_id == "user_123"
    assert %Fizz.Workflows.ExecutionContext{} = context.execution_context
    assert context.execution_context.scope == scope
    assert context.execution_context.project_id == "project_123"
    assert context.execution_context.credential_resolver == resolver
  end
end
