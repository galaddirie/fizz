defmodule Fizz.TestSupport.CatalogValidation.AcmeDocsTrigger do
  @behaviour Fizz.Triggers.Source

  @impl true
  def source_key(_params, _context), do: "acme_docs"

  @impl true
  def init_cursor(_params, _context), do: {:ok, %{}}

  @impl true
  def poll(_params, cursor, _context), do: {:ok, %{events: [], cursor: cursor || %{}}}

  @impl true
  def commit(_params, _checkpoint, _context), do: :ok

  @impl true
  def event_id(event), do: Map.fetch!(event, "id")
end
