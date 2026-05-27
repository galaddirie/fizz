defmodule Fizz.Accounts.ExternalAuthBoundaryTest do
  use ExUnit.Case, async: true

  test "accounts auth primitives do not depend on integration provider catalog ownership" do
    external_auth_source = File.read!("lib/fizz/accounts/external_auth.ex")
    api_credential_source = File.read!("lib/fizz/accounts/api_credential.ex")

    refute external_auth_source =~ "Fizz.Integrations.Auth.ProviderCatalog"
    refute api_credential_source =~ "Fizz.Integrations.Auth.ProviderCatalog"
  end
end
