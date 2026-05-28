defmodule Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders do
  @moduledoc false

  alias Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders.Registry

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(%{"model" => %{"model_spec" => model_spec}} = request, context)
      when is_binary(model_spec) do
    with {:ok, prefix} <- model_spec_prefix(model_spec),
         {:ok, provider_module} <- Registry.fetch(prefix) do
      provider_module.generate(request, context)
    end
  end

  def generate(_request, _context), do: {:error, :missing_model_spec}

  defp model_spec_prefix(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [prefix, _model] when prefix != "" -> {:ok, prefix}
      _ -> {:error, {:invalid_model_spec, model_spec}}
    end
  end
end
