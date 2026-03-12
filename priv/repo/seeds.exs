# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Fizz.Repo
alias Fizz.Accounts
alias Fizz.Accounts.{Workspace, WorkspaceMembership}

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
      IO.puts("⚠️  No workspace found for #{user1.email}. Skipping workspace seed updates.")
      IO.puts("   Create a workspace first, then rerun the seeds.")
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

IO.puts("\n📋 Workflow seeds have been removed.")
IO.puts("✅ Shared workspace setup is complete.")
IO.puts("\n🎉 Seeding completed!")
