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

  describe "AI model fields" do
    test "OpenAI model field uses the catalog-backed search resolver" do
      {:ok, openai_type} = Fizz.Integrations.Steps.Registry.get("openai_model")

      model_schema = get_in(openai_type.config_schema, ["properties", "model"])

      assert model_schema["type"] == "string"
      assert get_in(model_schema, ["ui", "component"]) == "search"

      assert get_in(model_schema, ["ui", "resolver"]) ==
               Fizz.Integrations.Library.OpenAI.ModelResolver
    end

    test "Anthropic model field uses the catalog-backed search resolver" do
      {:ok, anthropic_type} = Fizz.Integrations.Steps.Registry.get("anthropic_model")

      model_schema = get_in(anthropic_type.config_schema, ["properties", "model"])

      assert model_schema["type"] == "string"
      assert get_in(model_schema, ["ui", "component"]) == "search"

      assert get_in(model_schema, ["ui", "resolver"]) ==
               Fizz.Integrations.Library.Anthropic.ModelResolver

      default_config = Fizz.Integrations.Steps.Registry.get_default_config(anthropic_type.id)

      assert default_config["model"] == "claude-sonnet-4-6"
    end
  end
end
