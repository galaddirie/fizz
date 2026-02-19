defmodule Fizz.WorkflowsTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Fizz.Workflows.Workflow
  alias Fizz.Workflows.WorkflowDraft
  alias Fizz.Workflows

  describe "workflow changesets and step identity" do
    test "update_changeset/2 ignores workspace_id and user_id changes" do
      workflow = %Workflow{
        name: "Original",
        workspace_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      changeset =
        Workflow.update_changeset(workflow, %{
          name: "Renamed",
          workspace_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
      assert get_change(changeset, :name) == "Renamed"
      refute Map.has_key?(changeset.changes, :workspace_id)
      refute Map.has_key?(changeset.changes, :user_id)
    end

    test "create_changeset/2 includes workspace_id and user_id" do
      attrs = %{
        name: "Created",
        workspace_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      changeset = Workflow.create_changeset(%Workflow{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :workspace_id) == attrs.workspace_id
      assert get_change(changeset, :user_id) == attrs.user_id
    end

    test "workflow draft changeset casts editor_state" do
      workflow_id = Ecto.UUID.generate()

      changeset =
        WorkflowDraft.changeset(%WorkflowDraft{workflow_id: workflow_id}, %{
          workflow_id: workflow_id,
          editor_state: %{"locks" => %{"step_1" => "user_1"}}
        })

      assert changeset.valid?
      assert get_change(changeset, :editor_state) == %{"locks" => %{"step_1" => "user_1"}}
    end

    test "generate_unique_step_identity/2 works for string-key maps" do
      existing_steps = [%{"name" => "HTTP Request", "id" => "http_request"}]

      assert {"HTTP Request 2", "http_request_2"} =
               Workflows.generate_unique_step_identity(existing_steps, "HTTP Request")
    end
  end
end
