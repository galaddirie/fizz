defmodule Fizz.Fields.CredentialSecretTest do
  use ExUnit.Case, async: false

  alias Fizz.Fields
  alias Fizz.Fields.Credential

  setup do
    previous_providers = Application.get_env(:fizz, :integration_providers)

    previous_replace_providers =
      Application.get_env(:fizz, :replace_integration_providers_for_test)

    on_exit(fn ->
      restore_env(:integration_providers, previous_providers)
      restore_env(:replace_integration_providers_for_test, previous_replace_providers)
    end)

    :ok
  end

  describe "secret_value/2" do
    test "extracts a single provider secret field" do
      assert {:ok, "sk-test"} =
               Credential.secret_value("openai_api_key", %{
                 credentials: %{"secret" => " sk-test "}
               })
    end

    test "extracts multiple provider secret fields as JSON" do
      install_multi_secret_provider()

      assert {:ok, encoded} =
               Credential.secret_value("multi_api_key", %{
                 credentials: %{"client_id" => "client", "client_secret" => "secret"}
               })

      assert Jason.decode!(encoded) == %{
               "client_id" => "client",
               "client_secret" => "secret"
             }
    end

    test "rejects missing required secret fields" do
      install_multi_secret_provider()

      assert {:error, :missing_secret_value} =
               Credential.secret_value("multi_api_key", %{
                 credentials: %{"client_id" => "client", "client_secret" => ""}
               })
    end
  end

  defp install_multi_secret_provider do
    Application.put_env(:fizz, :replace_integration_providers_for_test, true)

    Application.put_env(:fizz, :integration_providers, [
      %{
        id: "multi_api_key",
        label: "Multi",
        logo_path: "/images/multi.svg",
        type: :api_key,
        credential_fields: [
          Fields.password("client_id", label: "Client ID", required?: true, default: ""),
          Fields.password("client_secret", label: "Client Secret", required?: true, default: "")
        ]
      }
    ])
  end

  defp restore_env(key, nil), do: Application.delete_env(:fizz, key)
  defp restore_env(key, value), do: Application.put_env(:fizz, key, value)
end
