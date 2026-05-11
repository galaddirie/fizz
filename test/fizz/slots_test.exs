defmodule Fizz.SlotsTest do
  use Fizz.DataCase, async: true

  alias Fizz.Accounts.ApiCredential
  alias Fizz.Accounts.Scope
  alias Fizz.Slots
  alias Fizz.Slots.Declaration
  alias Fizz.Workflows
  alias Fizz.WorkflowsFixtures

  describe "slot declarations" do
    test "walks nested config and normalizes slot declarations" do
      config = %{
        "credential_ref" => credential_slot("openai_api_key"),
        "nested" => [%{"value" => credential_slot("github_oauth", "oauth")}]
      }

      declarations = config |> Declaration.walk() |> Enum.sort_by(& &1.path)

      assert [
               %{path: ["credential_ref"], declaration: openai},
               %{path: ["nested", "0", "value"], declaration: github}
             ] = declarations

      assert {:ok,
              %{
                kind: "credential",
                slot_key: "auth",
                spec: %{"provider" => "openai_api_key", "auth_type" => "api_key"}
              }} = Declaration.normalize(openai)

      assert :ok = Declaration.validate(github)
    end

    test "reports missing and unregistered slot declaration fields" do
      assert {:error, "slot is missing kind"} =
               Declaration.validate(%{"$slot" => true, "slot_key" => "auth", "spec" => %{}})

      assert {:error, "slot kind \"missing\" is not registered"} =
               Declaration.validate(%{
                 "$slot" => true,
                 "kind" => "missing",
                 "slot_key" => "auth",
                 "spec" => %{}
               })
    end
  end

  describe "required_slots/1" do
    test "returns normalized slot descriptors for workflow step maps" do
      steps = [
        %{id: "step_a", config: %{"credential_ref" => credential_slot("openai_api_key")}},
        %{id: "step_b", config: %{}}
      ]

      assert [
               %{
                 step_id: "step_a",
                 field: "credential_ref",
                 kind: "credential",
                 slot_key: "auth",
                 spec: %{"provider" => "openai_api_key", "auth_type" => "api_key"}
               }
             ] = Slots.required_slots(steps)
    end
  end

  describe "candidate_options/3" do
    test "returns a tagged error for unknown slot kinds" do
      assert {:error, :unknown_slot_kind} = Slots.candidate_options("missing", %{}, %Scope{})
    end
  end

  describe "upsert_binding/3" do
    test "persists a binding when it matches the slot declaration spec" do
      scope = WorkflowsFixtures.project_scope_fixture()
      version = draft_with_credential_slot(scope, "openai_api_key")
      credential = insert_api_credential!(scope.user.id, scope.organization_id, "openai_api_key")

      assert {:ok, binding} =
               Slots.upsert_binding(version, scope, %{
                 user_id: scope.user.id,
                 workflow_definition_id: version.workflow_definition_id,
                 step_id: hd(version.steps).id,
                 slot_key: "auth",
                 kind: "credential",
                 binding_data: %{"credential_id" => credential.id},
                 workos_organization_id: scope.organization_id
               })

      assert binding.binding_data == %{"credential_id" => credential.id}
    end

    test "rejects a credential binding that does not satisfy the declaration spec" do
      scope = WorkflowsFixtures.project_scope_fixture()
      version = draft_with_credential_slot(scope, "openai_api_key")

      credential =
        insert_api_credential!(scope.user.id, scope.organization_id, "anthropic_api_key")

      assert {:error, changeset} =
               Slots.upsert_binding(version, scope, %{
                 user_id: scope.user.id,
                 workflow_definition_id: version.workflow_definition_id,
                 step_id: hd(version.steps).id,
                 slot_key: "auth",
                 kind: "credential",
                 binding_data: %{"credential_id" => credential.id},
                 workos_organization_id: scope.organization_id
               })

      assert "credential_not_available" in errors_on(changeset).binding_data
    end
  end

  defp credential_slot(provider, auth_type \\ "api_key") do
    %{
      "$slot" => true,
      "kind" => "credential",
      "slot_key" => "auth",
      "spec" => %{"provider" => provider, "auth_type" => auth_type}
    }
  end

  defp draft_with_credential_slot(scope, provider) do
    {:ok, %{draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Slot workflow #{System.unique_integer([:positive])}",
        description: "Slot test"
      })

    step =
      WorkflowsFixtures.step(%{
        type_id: "openai_image_generation",
        name: "Image",
        config: %{"credential_ref" => credential_slot(provider)}
      })

    attrs = WorkflowsFixtures.snapshot_attrs(%{steps: [step]})

    {:ok, version} = Workflows.save_draft(scope, draft, attrs)
    version
  end

  defp insert_api_credential!(user_id, organization_id, provider) do
    unique = System.unique_integer([:positive])

    %ApiCredential{}
    |> ApiCredential.changeset(%{
      user_id: user_id,
      workos_organization_id: organization_id,
      provider: provider,
      provider_label: "Credential #{unique}",
      vault_object_id: "vault_obj_#{unique}",
      vault_object_name: "vault_name_#{unique}"
    })
    |> Repo.insert!()
  end
end
