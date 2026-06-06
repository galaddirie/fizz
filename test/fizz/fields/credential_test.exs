defmodule Fizz.Fields.CredentialTest do
  use Fizz.DataCase, async: true

  alias Fizz.Accounts.{ApiCredential, OauthConnection}
  alias Fizz.Fields.Credential
  alias Fizz.Workflows
  alias Fizz.Workflows.CredentialDefaults
  alias Fizz.WorkflowsFixtures

  describe "credential declarations" do
    test "walks nested config and normalizes credential declarations" do
      config = %{
        "credential_ref" => credential_declaration("openai_api_key"),
        "nested" => [%{"value" => credential_declaration("github_oauth", "oauth")}]
      }

      declarations = config |> Credential.walk() |> Enum.sort_by(& &1.path)

      assert [
               %{path: ["credential_ref"], declaration: openai},
               %{path: ["nested", "0", "value"], declaration: github}
             ] = declarations

      assert {:ok,
              %{
                requirement_key: "auth",
                provider: "openai_api_key",
                auth_type: "api_key"
              }} = Credential.normalize(openai)

      assert :ok = Credential.validate(github)
    end

    test "reports missing and invalid credential declaration fields" do
      assert {:error, "credential is missing provider"} =
               Credential.validate(%{
                 "$credential" => true,
                 "requirement_key" => "auth",
                 "auth_type" => "api_key"
               })

      assert {:error, "credential auth_type must be api_key or oauth"} =
               Credential.validate(%{
                 "$credential" => true,
                 "requirement_key" => "auth",
                 "provider" => "openai_api_key",
                 "auth_type" => "password"
               })
    end
  end

  describe "required_credentials/1" do
    test "returns normalized credential descriptors for workflow step maps" do
      steps = [
        %{id: "step_a", config: %{"credential_ref" => credential_declaration("openai_api_key")}},
        %{id: "step_b", config: %{}}
      ]

      assert [
               %{
                 step_id: "step_a",
                 field: "credential_ref",
                 requirement_key: "auth",
                 provider: "openai_api_key",
                 auth_type: "api_key"
               }
             ] = Credential.required_credentials(steps)
    end
  end

  describe "credential defaults" do
    test "restores missing credential declarations from step default config" do
      step =
        WorkflowsFixtures.step(%{
          type_id: "google_sheets_append_row",
          config: %{"credential_ref" => nil, "spreadsheet_id" => "sheet", "values" => %{}}
        })

      assert [
               %{
                 config: %{
                   "credential_ref" => %{
                     "$credential" => true,
                     "requirement_key" => "auth",
                     "provider" => "google_oauth",
                     "auth_type" => "oauth"
                   }
                 }
               }
             ] = CredentialDefaults.normalize_steps([step])
    end

    test "does not overwrite concrete legacy credential refs" do
      legacy_ref = %{
        "id" => Ecto.UUID.generate(),
        "provider" => "google_oauth",
        "auth_type" => "oauth"
      }

      step =
        WorkflowsFixtures.step(%{
          type_id: "google_sheets_append_row",
          config: %{"credential_ref" => legacy_ref, "spreadsheet_id" => "sheet", "values" => %{}}
        })

      assert [%{config: %{"credential_ref" => ^legacy_ref}}] =
               CredentialDefaults.normalize_steps([step])
    end
  end

  describe "ensure_auto_bindings/3" do
    test "auto-binds one available WorkOS OAuth connection for restored credentials" do
      scope = WorkflowsFixtures.project_scope_fixture()

      append_step =
        WorkflowsFixtures.step(%{
          type_id: "google_sheets_append_row",
          config: %{
            "credential_ref" => nil,
            "spreadsheet_id" => "sheet_123",
            "values" => %{"A" => "1"}
          }
        })

      {:ok, %{draft: draft}} =
        Workflows.create_definition(scope, %{
          name: "OAuth credential workflow #{System.unique_integer([:positive])}",
          description: "Credential auto-bind test"
        })

      {:ok, version} =
        Workflows.save_draft(
          scope,
          draft,
          WorkflowsFixtures.snapshot_attrs(%{steps: [append_step]})
        )

      connection = insert_oauth_connection!(scope.user.id, scope.organization_id, "google_oauth")

      assert {:ok, [binding]} = Credential.ensure_auto_bindings(version, scope.user.id, scope)
      assert binding.step_id == append_step.id
      assert binding.requirement_key == "auth"
      assert binding.binding_data == %{"credential_id" => connection.id}
      assert Credential.readiness(version, scope.user.id, scope) == :ready
    end
  end

  describe "candidate_options/2" do
    test "returns a tagged error for invalid scope" do
      assert {:error, :invalid_scope} =
               Credential.candidate_options(credential_declaration("openai_api_key"), nil)
    end
  end

  describe "upsert_binding/3" do
    test "persists a binding when it matches the credential requirement" do
      scope = WorkflowsFixtures.project_scope_fixture()
      version = draft_with_credential_requirement(scope, "openai_api_key")
      credential = insert_api_credential!(scope.user.id, scope.organization_id, "openai_api_key")

      assert {:ok, binding} =
               Credential.upsert_binding(version, scope, %{
                 user_id: scope.user.id,
                 workflow_definition_id: version.workflow_definition_id,
                 step_id: hd(version.steps).id,
                 requirement_key: "auth",
                 binding_data: %{"credential_id" => credential.id},
                 workos_organization_id: scope.organization_id
               })

      assert binding.binding_data == %{"credential_id" => credential.id}
    end

    test "rejects a credential binding that does not satisfy the requirement" do
      scope = WorkflowsFixtures.project_scope_fixture()
      version = draft_with_credential_requirement(scope, "openai_api_key")

      credential =
        insert_api_credential!(scope.user.id, scope.organization_id, "anthropic_api_key")

      assert {:error, changeset} =
               Credential.upsert_binding(version, scope, %{
                 user_id: scope.user.id,
                 workflow_definition_id: version.workflow_definition_id,
                 step_id: hd(version.steps).id,
                 requirement_key: "auth",
                 binding_data: %{"credential_id" => credential.id},
                 workos_organization_id: scope.organization_id
               })

      assert "credential_not_available" in errors_on(changeset).binding_data
    end
  end

  defp credential_declaration(provider, auth_type \\ "api_key") do
    %{
      "$credential" => true,
      "requirement_key" => "auth",
      "provider" => provider,
      "auth_type" => auth_type
    }
  end

  defp draft_with_credential_requirement(scope, provider) do
    {:ok, %{draft: draft}} =
      Workflows.create_definition(scope, %{
        name: "Credential workflow #{System.unique_integer([:positive])}",
        description: "Credential test"
      })

    step =
      WorkflowsFixtures.step(%{
        type_id: "openai_image_generation",
        name: "Image",
        config: %{"credential_ref" => credential_declaration(provider)}
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

  defp insert_oauth_connection!(user_id, organization_id, provider) do
    %OauthConnection{}
    |> OauthConnection.changeset(%{
      workos_organization_id: organization_id,
      user_id: user_id,
      provider: provider,
      status: :active
    })
    |> Repo.insert!()
  end
end
