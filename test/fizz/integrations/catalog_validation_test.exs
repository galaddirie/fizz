defmodule Fizz.Integrations.CatalogValidationTest do
  use ExUnit.Case, async: false

  alias Fizz.Integrations.Auth.ProviderCatalog
  alias Fizz.Integrations.Catalog.IntegrationRegistry, as: IntegrationRegistry
  alias Fizz.Integrations.Steps.Registry, as: StepRegistry

  setup do
    previous_providers = Application.get_env(:fizz, :integration_providers)

    previous_replace_providers =
      Application.get_env(:fizz, :replace_integration_providers_for_test)

    previous_integrations = Application.get_env(:fizz, :integrations)
    previous_replace_integrations = Application.get_env(:fizz, :replace_integrations_for_test)

    on_exit(fn ->
      restore_env(:integration_providers, previous_providers)
      restore_env(:replace_integration_providers_for_test, previous_replace_providers)
      restore_env(:integrations, previous_integrations)
      restore_env(:replace_integrations_for_test, previous_replace_integrations)
    end)

    :ok
  end

  describe "provider catalog extension" do
    test "configured providers append to built-ins by default" do
      Application.put_env(:fizz, :integration_providers, [acme_provider()])

      provider_ids = ProviderCatalog.providers() |> Enum.map(& &1.id)

      assert "openai_api_key" in provider_ids
      assert "acme_api_key" in provider_ids
    end

    test "providers can only replace built-ins with an explicit replacement flag" do
      Application.put_env(:fizz, :integration_providers, [acme_provider()])
      Application.put_env(:fizz, :replace_integration_providers_for_test, true)

      assert [%{id: "acme_api_key"}] = ProviderCatalog.providers()
      assert {:error, :unknown_provider} = ProviderCatalog.provider("openai_api_key")
    end

    test "duplicate provider IDs raise during catalog load" do
      Application.put_env(:fizz, :integration_providers, [
        Map.put(acme_provider(), :id, "openai_api_key")
      ])

      assert_raise ArgumentError, ~r/duplicate integration provider IDs/, fn ->
        ProviderCatalog.providers()
      end
    end

    test "missing provider icons raise during catalog load" do
      provider = acme_provider() |> Map.delete(:logo_path)
      Application.put_env(:fizz, :integration_providers, [provider])

      assert_raise ArgumentError, ~r/missing logo_path/, fn ->
        ProviderCatalog.providers()
      end
    end

    test "malformed provider credential fields raise during catalog load" do
      provider =
        Map.put(acme_provider(), :credential_fields, [
          %{key: "secret", type: :password, component: "bespoke"}
        ])

      Application.put_env(:fizz, :integration_providers, [provider])

      assert_raise ArgumentError, ~r/unsupported component/, fn ->
        ProviderCatalog.providers()
      end
    end
  end

  describe "integration registry extension" do
    test "configured integrations append to built-ins by default" do
      modules =
        IntegrationRegistry.modules_for_load(
          modules: [Fizz.TestSupport.CatalogValidation.AcmeDocs]
        )

      assert Fizz.Integrations.Library.Google.Sheets in modules
      assert Fizz.TestSupport.CatalogValidation.AcmeDocs in modules
    end

    test "integrations can only replace built-ins with an explicit replacement flag" do
      assert [Fizz.TestSupport.CatalogValidation.AcmeDocs] =
               IntegrationRegistry.modules_for_load(
                 modules: [Fizz.TestSupport.CatalogValidation.AcmeDocs],
                 replace_modules: true
               )
    end

    test "duplicate integration IDs raise during catalog load" do
      modules =
        IntegrationRegistry.modules_for_load(modules: [Fizz.Integrations.Library.Google.Sheets])

      entries = IntegrationRegistry.entries_for_modules!(modules)

      assert_raise ArgumentError, ~r/duplicate integration IDs/, fn ->
        IntegrationRegistry.validate_entries!(entries)
      end
    end

    test "unknown integration providers raise during catalog load" do
      entries =
        IntegrationRegistry.entries_for_modules!([
          Fizz.TestSupport.CatalogValidation.UnknownProviderIntegration
        ])

      assert_raise ArgumentError, ~r/uses unknown provider missing_oauth/, fn ->
        IntegrationRegistry.validate_entries!(entries)
      end
    end
  end

  describe "step registry validation" do
    test "duplicate step type IDs raise during catalog load" do
      assert_raise RuntimeError, ~r/Duplicate step type IDs/, fn ->
        StepRegistry.types_for_modules!([
          Fizz.Integrations.Library.Fizz.Builtins.ManualInput,
          Fizz.Integrations.Library.Fizz.Builtins.ManualInput
        ])
      end
    end

    test "duplicate dynamic step registrations raise before replacing an existing type" do
      {:ok, step_type} = StepRegistry.get("manual_input")

      assert_raise ArgumentError, ~r/already registered/, fn ->
        StepRegistry.register(step_type)
      end
    end

    test "missing step icons raise during catalog load" do
      assert_raise ArgumentError, ~r/missing icon/, fn ->
        StepRegistry.types_for_modules!([Fizz.TestSupport.CatalogValidation.MissingIconStep])
      end
    end

    test "unsupported UI components raise during catalog load" do
      assert_raise ArgumentError, ~r/unsupported component "bespoke"/, fn ->
        StepRegistry.types_for_modules!([
          Fizz.TestSupport.CatalogValidation.UnsupportedComponentStep
        ])
      end
    end

    test "malformed resource metadata raises during catalog load" do
      assert_raise ArgumentError, ~r/resource_locator must be a map/, fn ->
        StepRegistry.types_for_modules!([
          Fizz.TestSupport.CatalogValidation.InvalidResourceMetadataStep
        ])
      end
    end

    test "resource mapper references to missing fields raise during catalog load" do
      assert_raise ArgumentError, ~r/references unknown field "missing_resource"/, fn ->
        StepRegistry.types_for_modules!([
          Fizz.TestSupport.CatalogValidation.InvalidResourceMapperReferenceStep
        ])
      end
    end
  end

  defp acme_provider do
    %{
      id: "acme_api_key",
      label: "Acme",
      logo_path: "/images/acme.svg",
      type: :api_key
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:fizz, key)
  defp restore_env(key, value), do: Application.put_env(:fizz, key, value)
end
