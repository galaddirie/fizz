defmodule Fizz.TestSupport.CatalogValidation.MissingCredentialDefaultStep do
  use Fizz.Steps.Definition,
    id: "missing_credential_default_step",
    name: "Missing Credential Default Step",
    category: "Test",
    description: "Invalid step missing the default credential declaration.",
    icon: "hero-key",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour
  @credential_field Fizz.Fields.credential("google_oauth", :oauth,
                      key: "credential_ref",
                      label: "Google Account"
                    )

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" => Fizz.Fields.to_schema_property(@credential_field)
    }
  }

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
