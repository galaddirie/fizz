defmodule Fizz.Integrations.Library.Anthropic.ModelResolver do
  @moduledoc false

  alias Fizz.Integrations.AI.ModelCatalog

  @spec resolve(map()) :: {:ok, [map()]}
  def resolve(%{q: query}) do
    {:ok, ModelCatalog.chat_model_options(:anthropic, query)}
  end

  def resolve(_request) do
    {:ok, ModelCatalog.chat_model_options(:anthropic)}
  end
end
