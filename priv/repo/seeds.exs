# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Fizz.Repo
alias Fizz.Accounts
alias Fizz.Accounts.{User, Scope, Workspace, WorkspaceMembership}
alias Fizz.Workflows
alias Fizz.Workflows.Workflow

IO.puts("🌱 Seeding database...")

# Check for existing users
user1 = Accounts.get_user_by_email("galad360@gmail.com")
user2 = Accounts.get_user_by_email("galad.work@gmail.com")

if is_nil(user1) or is_nil(user2) do
  IO.puts(
    "⚠️  Skipping seeds: Both users (galad360@gmail.com and galad.work@gmail.com) must exist."
  )

  IO.puts("   Found:")
  IO.puts("     galad360@gmail.com: #{if user1, do: "✓", else: "✗"}")
  IO.puts("     galad.work@gmail.com: #{if user2, do: "✓", else: "✗"}")
  System.halt(0)
end

IO.puts("✅ Found both users:")
IO.puts("   galad360@gmail.com: #{user1.email}")
IO.puts("   galad.work@gmail.com: #{user2.email}")

# Find or create a shared workspace for both users
import Ecto.Query

# First, try to find an existing workspace that both users are members of
shared_workspace =
  Repo.one(
    from w in Workspace,
      join: wm1 in WorkspaceMembership,
      on: wm1.workspace_id == w.id and wm1.user_id == ^user1.id,
      join: wm2 in WorkspaceMembership,
      on: wm2.workspace_id == w.id and wm2.user_id == ^user2.id,
      limit: 1
  )

workspace1 =
  if shared_workspace do
    IO.puts("✅ Found existing shared workspace: #{shared_workspace.name}")
    shared_workspace
  else
    # Check if user1 has any workspace we can use
    user1_workspace =
      Repo.one(
        from w in Workspace,
          join: wm in WorkspaceMembership,
          on: wm.workspace_id == w.id,
          where: wm.user_id == ^user1.id,
          limit: 1
      )

    if is_nil(user1_workspace) do
      IO.puts("⚠️  No workspace found for #{user1.email}. Skipping workflow creation.")
      IO.puts("   Workflows require a workspace. Please create one first.")
      System.halt(0)
    end

    IO.puts("✅ Using existing workspace for #{user1.email}: #{user1_workspace.name}")
    IO.puts("   Adding #{user2.email} to the workspace...")

    # Add user2 to user1's workspace
    membership =
      Repo.get_by(WorkspaceMembership, workspace_id: user1_workspace.id, user_id: user2.id) ||
        %WorkspaceMembership{workspace_id: user1_workspace.id, user_id: user2.id}

    case membership
         |> WorkspaceMembership.changeset(%{role: :member})
         |> Repo.insert_or_update() do
      {:ok, _membership} ->
        IO.puts("   ✅ Added #{user2.email} as member to workspace: #{user1_workspace.name}")
        user1_workspace

      {:error, changeset} ->
        IO.puts("   ⚠️  Failed to add #{user2.email} to workspace: #{inspect(changeset.errors)}")
        user1_workspace
    end
  end

# Create scope for user1 with workspace and organization
# Note: For seeds, we'll create a minimal scope. In production, use Accounts.build_scope/3
scope1 =
  Scope.for_user(user1)
  |> Scope.with_organization_id(workspace1.workos_organization_id)
  |> Scope.with_workspace(workspace1)
  |> Scope.with_workspace_role(:admin)
  |> Scope.with_organization_role(:owner)

IO.puts("\n📋 Creating example workflows...")

# Helper function to create workflow with draft
create_workflow_with_draft = fn attrs, steps, connections ->
  case Workflows.create_workflow(scope1, attrs) do
    {:ok, workflow} ->
      draft_attrs = %{
        steps: steps,
        connections: connections,
        settings: %{timeout_ms: 300_000, max_retries: 3}
      }

      case Workflows.update_workflow_draft(scope1, workflow, draft_attrs) do
        {:ok, _draft} ->
          workflow

        {:error, reason} ->
          IO.puts(
            "⚠️  Warning: Failed to create draft for workflow #{workflow.name}: #{inspect(reason)}"
          )

          workflow
      end

    {:error, reason} ->
      IO.puts("⚠️  Failed to create workflow #{attrs[:name]}: #{inspect(reason)}")
      nil
  end
end

# ============================================================================
# Example 1: Linear Workflow - Simple sequential data processing
# ============================================================================
IO.puts("Creating Linear Workflow...")

linear_steps = [
  %{
    id: "start",
    type_id: "manual_input",
    name: "Start",
    config: %{
      "trigger_data" =>
        "{\"name\": \"John Doe\", \"timestamp\": \"2026-01-04 20:00:00\", \"arr\":[1,2,3,4,5]}"
    },
    position: %{"x" => -161.17957584024998, "y" => -569.2425531914893}
  },
  %{
    id: "format_greeting",
    type_id: "format",
    name: "Format Greeting",
    config: %{"template" => "Hello {{json.name}}! Welcome to the workflow."},
    position: %{"x" => 40.66991013933023, "y" => 70.26862929139838}
  },
  %{
    id: "add_timestamp",
    type_id: "format",
    name: "Add Timestamp",
    config: %{"template" => "{{json.greeting}} Processed at {{json.timestamp}}"},
    position: %{"x" => 431.25889887340765, "y" => 78.97413492435965}
  },
  %{
    id: "end",
    type_id: "debug",
    name: "End",
    config: %{"message" => "Linear workflow completed"},
    position: %{"x" => 1062.82042415975, "y" => -720.2425531914893}
  },
  %{
    id: "webhook_trigger",
    type_id: "webhook_trigger",
    name: "Webhook Trigger",
    config: %{
      "http_method" => "POST",
      "path" => "7f011ee3-555d-418f-bc6b-603f21983f7a",
      "response_mode" => "immediate",
      "validate_input" => false
    },
    position: %{"x" => -161.17957584024998, "y" => -418.24255319148926}
  },
  %{
    id: "split_items",
    type_id: "splitter",
    name: "Split Items",
    config: %{"field" => "{{ json.arr }}"},
    position: %{"x" => 246.82042415975002, "y" => -493.74255319148926}
  },
  %{
    id: "math",
    type_id: "math",
    name: "Multiply by 10",
    config: %{
      "operand" => "{{ json }}",
      "operation" => "multiply",
      "value" => "10"
    },
    position: %{"x" => 654.82042415975, "y" => -569.2425531914893}
  },
  %{
    id: "math_2",
    type_id: "math",
    name: "Multiply by 1",
    config: %{
      "operand" => "{{ json }}",
      "operation" => "multiply",
      "value" => "1"
    },
    position: %{"x" => 654.82042415975, "y" => -418.24255319148926}
  },
  %{
    id: "format_string",
    type_id: "format",
    name: "Format String",
    config: %{"template" => "({{ json[0] }}, {{ json[1] }})"},
    position: %{"x" => 1062.82042415975, "y" => -493.74255319148926}
  },
  %{
    id: "aggregate_items",
    type_id: "aggregator",
    name: "Aggregate Items",
    config: %{},
    position: %{"x" => 1470.82042415975, "y" => -493.74255319148926}
  },
  %{
    id: "format_string_2",
    type_id: "format",
    name: "Format String 2",
    config: %{"template" => "{{ json }}"},
    position: %{"x" => 1878.82042415975, "y" => -493.74255319148926}
  }
]

linear_connections = [
  %{
    id: "start_to_format",
    source_step_id: "start",
    source_output: "main",
    target_step_id: "format_greeting",
    target_input: "main"
  },
  %{
    id: "format_to_add_timestamp",
    source_step_id: "format_greeting",
    source_output: "main",
    target_step_id: "add_timestamp",
    target_input: "main"
  },
  %{
    id: "add_timestamp_to_end",
    source_step_id: "add_timestamp",
    source_output: "main",
    target_step_id: "end",
    target_input: "main"
  },
  %{
    id: "2bdb85af-0e52-42d5-a92e-47bad4b23c11",
    source_step_id: "start",
    source_output: "main",
    target_step_id: "split_items",
    target_input: "main"
  },
  %{
    id: "0eff119f-e1dd-4e8e-8d95-fdad64b06641",
    source_step_id: "split_items",
    source_output: "main",
    target_step_id: "math",
    target_input: "main"
  },
  %{
    id: "af9d53ea-c06c-4ee6-952a-c1406b937726",
    source_step_id: "split_items",
    source_output: "main",
    target_step_id: "math_2",
    target_input: "main"
  },
  %{
    id: "4af4bde9-42ab-4b44-9589-d43109b5e869",
    source_step_id: "math",
    source_output: "main",
    target_step_id: "format_string",
    target_input: "main"
  },
  %{
    id: "995449ee-2925-46e1-a86e-532b28efb9c7",
    source_step_id: "math_2",
    source_output: "main",
    target_step_id: "format_string",
    target_input: "main"
  },
  %{
    id: "bb5c1a59-a6d1-49a3-94f7-916f07655412",
    source_step_id: "format_string",
    source_output: "main",
    target_step_id: "aggregate_items",
    target_input: "main"
  },
  %{
    id: "d7a53977-73ca-4654-aa9f-fe181c55f281",
    source_step_id: "aggregate_items",
    source_output: "main",
    target_step_id: "format_string_2",
    target_input: "main"
  }
]

linear_workflow =
  create_workflow_with_draft.(
    %{
      name: "Linear Data Processing",
      description: "A simple linear workflow that processes data sequentially"
    },
    linear_steps,
    linear_connections
  )

if linear_workflow, do: IO.puts("✅ Created Linear Workflow: #{linear_workflow.name}")

# ============================================================================
# Example 2: Branching Workflow - Conditional processing with if/else
# ============================================================================
IO.puts("Creating Branching Workflow...")

branching_steps = [
  %{
    id: "input",
    type_id: "manual_input",
    name: "Input",
    config: %{"trigger_data" => "{\"name\": \"Alice\", \"status\": \"active\"}"},
    position: %{"x" => 100, "y" => 150}
  },
  %{
    id: "check_status",
    type_id: "condition",
    name: "Check Status",
    config: %{"condition" => "{{json.status}} == 'active'"},
    position: %{"x" => 300, "y" => 150}
  },
  %{
    id: "active_path",
    type_id: "format",
    name: "Active User",
    config: %{"template" => "✅ User {{json.name}} is active"},
    position: %{"x" => 500, "y" => 100}
  },
  %{
    id: "inactive_path",
    type_id: "format",
    name: "Inactive User",
    config: %{"template" => "❌ User {{json.name}} is inactive"},
    position: %{"x" => 500, "y" => 200}
  },
  %{
    id: "output",
    type_id: "debug",
    name: "Output",
    config: %{"message" => "Branching workflow completed"},
    position: %{"x" => 700, "y" => 150}
  }
]

branching_connections = [
  %{
    id: "input_to_check",
    source_step_id: "input",
    source_output: "main",
    target_step_id: "check_status",
    target_input: "main"
  },
  %{
    id: "check_to_active",
    source_step_id: "check_status",
    source_output: "true",
    target_step_id: "active_path",
    target_input: "main"
  },
  %{
    id: "check_to_inactive",
    source_step_id: "check_status",
    source_output: "false",
    target_step_id: "inactive_path",
    target_input: "main"
  },
  %{
    id: "active_to_output",
    source_step_id: "active_path",
    source_output: "main",
    target_step_id: "output",
    target_input: "main"
  },
  %{
    id: "inactive_to_output",
    source_step_id: "inactive_path",
    source_output: "main",
    target_step_id: "output",
    target_input: "main"
  }
]

branching_workflow =
  create_workflow_with_draft.(
    %{
      name: "Branching User Status",
      description: "Conditional workflow that routes based on user status"
    },
    branching_steps,
    branching_connections
  )

if branching_workflow, do: IO.puts("✅ Created Branching Workflow: #{branching_workflow.name}")

IO.puts("\n🎉 Seeding completed!")
IO.puts("Note: Workflow sharing is handled through workspace memberships in this system.")
