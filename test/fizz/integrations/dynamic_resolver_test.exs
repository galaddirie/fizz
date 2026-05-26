defmodule Fizz.Integrations.DynamicResolverTest do
  use Fizz.DataCase, async: true

  alias Fizz.Accounts.{ApiCredential, Scope}
  alias Fizz.Integrations.DynamicResolver
  alias Fizz.Integrations.Google.Sheets.ColumnsResolver
  alias Fizz.Workflows.Embeds.Step
  alias Fizz.Workflows.WorkflowDefinitionVersion

  import Fizz.AccountsFixtures

  describe "resolve/4" do
    test "dispatches schema-declared resource mapper resolvers with metadata" do
      step = step("google_sheets_append_row")
      draft = draft_with_step(step)

      assert {:ok, result} =
               DynamicResolver.resolve(
                 draft,
                 %{
                   "node_id" => step.id,
                   "field_key" => "values",
                   "params" => %{"mode" => "sheets"}
                 },
                 %{},
                 []
               )

      assert result.resolver == ColumnsResolver
      assert result.options == []

      assert result.meta.depends_on == [
               "credential_ref",
               "spreadsheet_id",
               "sheet_name",
               "table_id"
             ]

      assert result.meta.resource_mapper["kind"] == "google_sheets.row_values"
      assert result.meta.resource_mapper["lookups"]["primary_resource"]["mode"] == "sheets"
      assert result.meta.params["mode"] == "sheets"
    end

    test "keeps schema credential constraints authoritative over client params" do
      user = user_fixture()
      organization_id = "org_dynamic_resolver_#{System.unique_integer([:positive])}"
      scope = Scope.for_user(user) |> Scope.with_organization_id(organization_id)

      _openai_credential =
        insert_api_credential!(user.id, organization_id, "openai_api_key", "OpenAI Primary")

      _anthropic_credential =
        insert_api_credential!(
          user.id,
          organization_id,
          "anthropic_api_key",
          "Anthropic Primary"
        )

      step = step("openai_model")
      draft = draft_with_step(step)

      assert {:ok, result} =
               DynamicResolver.resolve(
                 draft,
                 %{
                   "node_id" => step.id,
                   "field_key" => "credential_ref",
                   "provider_filter" => ["anthropic_api_key"],
                   "auth_types" => ["api_key"],
                   "params" => %{
                     "provider_filter" => ["anthropic_api_key"],
                     "auth_types" => ["api_key"]
                   }
                 },
                 %{current_scope: scope},
                 []
               )

      assert [%{"display_name" => "OpenAI Primary", "provider" => "openai_api_key"}] =
               result.options

      assert result.meta.params["provider_filter"] == "openai_api_key"
      assert result.meta.params["auth_types"] == "api_key"
    end

    test "returns stable errors for missing step fields" do
      step = step("google_sheets_append_row")
      draft = draft_with_step(step)

      assert {:error, :field_not_found} =
               DynamicResolver.resolve(
                 draft,
                 %{"node_id" => step.id, "field_key" => "missing"},
                 %{},
                 []
               )
    end

    test "returns stable errors when draft is unavailable" do
      assert {:error, :draft_not_loaded} =
               DynamicResolver.resolve(
                 nil,
                 %{"node_id" => Ecto.UUID.generate(), "field_key" => "values"},
                 %{},
                 []
               )
    end
  end

  defp step(type_id) do
    %Step{
      id: Ecto.UUID.generate(),
      type_id: type_id,
      name: "Step",
      config: %{},
      position: %{}
    }
  end

  defp draft_with_step(%Step{} = step) do
    %WorkflowDefinitionVersion{
      id: Ecto.UUID.generate(),
      version: 1,
      status: :draft,
      steps: [step],
      connections: [],
      step_groups: [],
      viewport: %{},
      settings: %{}
    }
  end

  defp insert_api_credential!(user_id, organization_id, provider, provider_label) do
    unique = System.unique_integer([:positive])

    %ApiCredential{}
    |> ApiCredential.changeset(%{
      user_id: user_id,
      workos_organization_id: organization_id,
      provider: provider,
      provider_label: provider_label,
      vault_object_id: "vault_obj_#{unique}",
      vault_object_name: "vault_name_#{unique}"
    })
    |> Repo.insert!()
  end
end
