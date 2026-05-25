defmodule Fizz.TestSupport.CatalogValidation.AcmeDocsAction do
  @behaviour Fizz.Integrations.Operation

  @impl true
  def id, do: "acme_docs.action"

  @impl true
  def schema, do: %{"type" => "object"}

  @impl true
  def execute(_config, _input, _context), do: {:ok, %{}}
end
