defmodule Fizz.TestSupport.CatalogValidation.MissingCredentialDefaultStep do
  use Fizz.Steps.Definition,
    id: "missing_credential_default_step",
    name: "Missing Credential Default Step",
    category: "Test",
    description: "Invalid step missing the default slot declaration.",
    icon: "hero-key",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" =>
        Fizz.Slots.Field.credential_schema("google_oauth", :oauth, title: "Google Account")
    }
  }

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
