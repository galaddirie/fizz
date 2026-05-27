defmodule Fizz.TestSupport.CatalogValidation.AcmeDocsAction do
  @behaviour Fizz.Integrations.Operation

  alias Fizz.Integrations.OperationDefinition

  @impl true
  def id, do: "acme_docs.action"

  @impl true
  def definition do
    %OperationDefinition{
      id: id(),
      step_type_id: "acme_docs_action",
      version: 1,
      provider: "acme_api_key",
      integration: "acme_docs",
      kind: :action,
      module: __MODULE__,
      display: %{
        name: "Acme Docs Action",
        category: "Documents",
        icon: "/images/custom_api_key.svg",
        description: "Test action"
      },
      config_schema: %{"type" => "object"},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
