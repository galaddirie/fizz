defmodule Fizz.Integrations.CredentialFieldTest do
  use ExUnit.Case, async: true

  describe "credential fields" do
    test "credential fields use the credential component in config schema" do
      {:ok, openai_type} = Fizz.Integrations.Steps.Registry.get("openai_model")

      ui = get_in(openai_type.config_schema, ["properties", "credential_ref", "ui"])

      assert ui["component"] == "credential"
      assert ui["requirement_key"] == "auth"
      assert ui["provider"] == "openai_api_key"
      assert ui["auth_type"] == "api_key"
    end

    test "credential field default config is a credential declaration" do
      {:ok, openai_type} = Fizz.Integrations.Steps.Registry.get("openai_model")

      default_config = Fizz.Integrations.Steps.Registry.get_default_config(openai_type.id)

      assert %{
               "$credential" => true,
               "requirement_key" => "auth",
               "provider" => "openai_api_key",
               "auth_type" => "api_key"
             } = default_config["credential_ref"]
    end
  end
end
