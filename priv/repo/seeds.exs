# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Fizz.Repo
alias Fizz.Accounts
alias Fizz.Accounts.{Project, ProjectMembership}
alias Fizz.Accounts.Scope
alias Fizz.Workflows
alias Fizz.Workflows.WorkflowDefinition

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

# Find or create a shared project for both users
import Ecto.Query

# First, try to find an existing project that both users are members of
shared_project =
  Repo.one(
    from w in Project,
      join: wm1 in ProjectMembership,
      on: wm1.project_id == w.id and wm1.user_id == ^user1.id,
      join: wm2 in ProjectMembership,
      on: wm2.project_id == w.id and wm2.user_id == ^user2.id,
      limit: 1
  )

project1 =
  if shared_project do
    IO.puts("✅ Found existing shared project: #{shared_project.name}")
    shared_project
  else
    # Check if user1 has any project we can use
    user1_project =
      Repo.one(
        from w in Project,
          join: wm in ProjectMembership,
          on: wm.project_id == w.id,
          where: wm.user_id == ^user1.id,
          limit: 1
      )

    if is_nil(user1_project) do
      IO.puts("⚠️  No project found for #{user1.email}. Skipping project seed updates.")
      IO.puts("   Create a project first, then rerun the seeds.")
      System.halt(0)
    end

    IO.puts("✅ Using existing project for #{user1.email}: #{user1_project.name}")
    IO.puts("   Adding #{user2.email} to the project...")

    # Add user2 to user1's project
    membership =
      Repo.get_by(ProjectMembership, project_id: user1_project.id, user_id: user2.id) ||
        %ProjectMembership{project_id: user1_project.id, user_id: user2.id}

    case membership
         |> ProjectMembership.changeset(%{role: :member})
         |> Repo.insert_or_update() do
      {:ok, _membership} ->
        IO.puts("   ✅ Added #{user2.email} as member to project: #{user1_project.name}")
        user1_project

      {:error, changeset} ->
        IO.puts("   ⚠️  Failed to add #{user2.email} to project: #{inspect(changeset.errors)}")
        user1_project
    end
  end

scope1 =
  Scope.for_user(user1)
  |> Scope.with_organization_id(project1.workos_organization_id)
  |> Scope.with_project(project1)
  |> Scope.with_project_role(:admin)
  |> Scope.with_organization_role(:owner)

step = fn attrs ->
  Map.merge(
    %{
      id: Ecto.UUID.generate(),
      type_id: "debug",
      name: "Step",
      config: %{},
      position: %{"x" => 0, "y" => 0},
      notes: nil
    },
    attrs
  )
end

connection = fn attrs ->
  Map.merge(
    %{
      id: Ecto.UUID.generate(),
      source_output: "main",
      target_input: "main"
    },
    attrs
  )
end

snapshot_attrs = fn steps, connections ->
  %{
    steps: steps,
    connections: connections,
    step_groups: [],
    viewport: %{"x" => 0, "y" => 0, "zoom" => 1.0},
    settings: %{}
  }
end

ensure_workflow = fn definition_attrs, draft_attrs ->
  existing_definition =
    Repo.one(
      from definition in WorkflowDefinition,
        where:
          definition.project_id == ^project1.id and definition.name == ^definition_attrs.name and
            is_nil(definition.archived_at),
        limit: 1
    )

  case existing_definition do
    %WorkflowDefinition{} = definition ->
      IO.puts("↩️  Skipping existing workflow: #{definition.name}")
      {:ok, definition}

    nil ->
      with {:ok, %{definition: definition, draft: draft}} <-
             Workflows.create_definition(scope1, definition_attrs),
           {:ok, _saved_draft} <- Workflows.save_draft(scope1, draft, draft_attrs) do
        IO.puts("✅ Seeded workflow: #{definition.name}")
        {:ok, definition}
      else
        {:error, reason} ->
          IO.puts("⚠️  Failed to seed workflow #{definition_attrs.name}: #{inspect(reason)}")
          {:error, reason}
      end
  end
end

IO.puts("\n📋 Seeding initial workflow definitions...")

customer_intake_trigger =
  step.(%{
    type_id: "manual_input",
    name: "Manual Trigger",
    config: %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "email" => %{"type" => "string"},
          "message" => %{"type" => "string"}
        }
      }
    },
    position: %{"x" => 80, "y" => 160}
  })

customer_intake_debug =
  step.(%{
    type_id: "debug",
    name: "Inspect Request",
    config: %{"label" => "Incoming request", "level" => "info"},
    position: %{"x" => 360, "y" => 160}
  })

customer_intake_output =
  step.(%{
    type_id: "data_output",
    name: "Output",
    position: %{"x" => 640, "y" => 160}
  })

customer_intake_connections = [
  connection.(%{
    source_step_id: customer_intake_trigger.id,
    target_step_id: customer_intake_debug.id
  }),
  connection.(%{
    source_step_id: customer_intake_debug.id,
    target_step_id: customer_intake_output.id
  })
]

_ =
  ensure_workflow.(
    %{
      name: "Customer Intake",
      description: "Accept a request payload, inspect it, and emit the final output."
    },
    snapshot_attrs.(
      [customer_intake_trigger, customer_intake_debug, customer_intake_output],
      customer_intake_connections
    )
  )

status_trigger =
  step.(%{
    type_id: "manual_input",
    name: "Manual Trigger",
    config: %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "status" => %{"type" => "string"},
          "customer_id" => %{"type" => "string"}
        }
      }
    },
    position: %{"x" => 80, "y" => 220}
  })

status_condition =
  step.(%{
    type_id: "condition",
    name: "Status Is Active?",
    config: %{
      "condition" => "{{ input.status | eq: \"active\" }}",
      "true_output" => "active",
      "false_output" => "inactive"
    },
    position: %{"x" => 360, "y" => 220}
  })

status_active =
  step.(%{
    type_id: "debug",
    name: "Active Branch",
    config: %{"label" => "Active account", "level" => "info"},
    position: %{"x" => 680, "y" => 120}
  })

status_inactive =
  step.(%{
    type_id: "debug",
    name: "Inactive Branch",
    config: %{"label" => "Inactive account", "level" => "warn"},
    position: %{"x" => 680, "y" => 320}
  })

status_connections = [
  connection.(%{
    source_step_id: status_trigger.id,
    target_step_id: status_condition.id
  }),
  connection.(%{
    source_step_id: status_condition.id,
    source_output: "active",
    target_step_id: status_active.id
  }),
  connection.(%{
    source_step_id: status_condition.id,
    source_output: "inactive",
    target_step_id: status_inactive.id
  })
]

_ =
  ensure_workflow.(
    %{
      name: "Route By Status",
      description:
        "Branch a request into active and inactive paths using the new predicate syntax."
    },
    snapshot_attrs.(
      [status_trigger, status_condition, status_active, status_inactive],
      status_connections
    )
  )

split_trigger =
  step.(%{
    type_id: "manual_input",
    name: "Manual Trigger",
    config: %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "items" => %{
            "type" => "array",
            "items" => %{"type" => "number"}
          }
        }
      }
    },
    position: %{"x" => 80, "y" => 160}
  })

split_items =
  step.(%{
    type_id: "splitter",
    name: "Split Items",
    config: %{"field" => "items"},
    position: %{"x" => 320, "y" => 160}
  })

double_item =
  step.(%{
    type_id: "math",
    name: "Double Each Item",
    config: %{
      "operation" => "multiply",
      "value" => "{{ input }}",
      "operand" => 2
    },
    position: %{"x" => 560, "y" => 160}
  })

sum_results =
  step.(%{
    type_id: "aggregator",
    name: "Sum Results",
    config: %{"operation" => "sum"},
    position: %{"x" => 840, "y" => 160}
  })

split_output =
  step.(%{
    type_id: "data_output",
    name: "Output",
    position: %{"x" => 1120, "y" => 160}
  })

split_connections = [
  connection.(%{
    source_step_id: split_trigger.id,
    target_step_id: split_items.id
  }),
  connection.(%{
    source_step_id: split_items.id,
    target_step_id: double_item.id
  }),
  connection.(%{
    source_step_id: double_item.id,
    target_step_id: sum_results.id
  }),
  connection.(%{
    source_step_id: sum_results.id,
    target_step_id: split_output.id
  })
]

_ =
  ensure_workflow.(
    %{
      name: "Split And Sum Items",
      description: "Fan out a list of numbers, transform each item, then aggregate the results."
    },
    snapshot_attrs.(
      [split_trigger, split_items, double_item, sum_results, split_output],
      split_connections
    )
  )

IO.puts("✅ Shared project setup is complete.")
IO.puts("\n🎉 Seeding completed!")
