# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Fizz.Repo
alias Fizz.Accounts
alias Fizz.Accounts.{Project, ProjectMembership}

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

_ = project1

IO.puts("\n📋 Workflow seeds have been removed.")
IO.puts("✅ Shared project setup is complete.")
IO.puts("\n🎉 Seeding completed!")
