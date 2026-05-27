defmodule Fizz.Credentials.OptionsResolverTest do
  use Fizz.DataCase, async: true

  alias Fizz.Accounts.{ApiCredential, Scope}
  alias Fizz.Credentials.OptionsResolver

  import Fizz.AccountsFixtures

  describe "resolve/1" do
    test "filters credential options using provider_filter and auth_types params" do
      user = user_fixture()
      organization_id = "org_credentials_resolver_filters"
      scope = Scope.for_user(user) |> Scope.with_organization_id(organization_id)

      _openai_credential =
        insert_api_credential!(user.id, organization_id, "openai_api_key", "OpenAI Primary")

      _anthropic_credential =
        insert_api_credential!(user.id, organization_id, "anthropic_api_key", "Anthropic Primary")

      assert {:ok, options} =
               OptionsResolver.resolve(%{
                 q: "",
                 params: %{
                   "provider_filter" => ["openai_api_key"],
                   "auth_types" => ["api_key"]
                 },
                 context: %{current_scope: scope}
               })

      assert [option] = options
      assert option["provider"] == "openai_api_key"
      assert option["auth_type"] == "api_key"
      assert option["display_name"] == "OpenAI Primary"
      assert option["owner_user_id"] == user.id
    end

    test "applies search query with current credential params" do
      user = user_fixture()
      organization_id = "org_credentials_resolver_search"
      scope = Scope.for_user(user) |> Scope.with_organization_id(organization_id)

      _production =
        insert_api_credential!(user.id, organization_id, "openai_api_key", "OpenAI Production")

      _staging =
        insert_api_credential!(user.id, organization_id, "openai_api_key", "OpenAI Staging")

      assert {:ok, options} =
               OptionsResolver.resolve(%{
                 q: "production",
                 params: %{
                   "provider_filter" => ["openai_api_key"],
                   "auth_types" => ["api_key"]
                 },
                 context: %{current_scope: scope}
               })

      assert [option] = options
      assert option["display_name"] == "OpenAI Production"
      assert option["provider"] == "openai_api_key"
      assert option["auth_type"] == "api_key"
    end
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
