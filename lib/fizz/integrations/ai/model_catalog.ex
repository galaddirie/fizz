defmodule Fizz.Integrations.AI.ModelCatalog do
  @moduledoc """
  Catalog-backed model options for AI configuration fields.

  ReqLLM resolves models through LLMDB. This module keeps Fizz's model selectors
  on that same catalog while preserving plain provider-local model IDs in step
  config.
  """

  @type provider :: :openai | :anthropic

  @spec chat_model_options(provider(), String.t() | nil) :: [map()]
  def chat_model_options(provider, query \\ "") when provider in [:openai, :anthropic] do
    ensure_catalog_loaded()

    provider
    |> LLMDB.models()
    |> Enum.filter(&text_chat_model?/1)
    |> Enum.reject(&LLMDB.Model.retired?/1)
    |> filter_by_query(query)
    |> Enum.map(&option_from_model/1)
  end

  defp ensure_catalog_loaded do
    case LLMDB.providers() do
      [] -> LLMDB.load()
      _providers -> :ok
    end
  end

  defp text_chat_model?(%LLMDB.Model{} = model) do
    text_operation_supported?(model) and text_modality?(model, :input) and
      text_modality?(model, :output)
  end

  defp text_operation_supported?(%LLMDB.Model{execution: execution}) when is_map(execution) do
    case Map.get(execution, :text) || Map.get(execution, "text") do
      %{supported: true} -> true
      %{"supported" => true} -> true
      _operation -> false
    end
  end

  defp text_operation_supported?(%LLMDB.Model{}), do: false

  defp text_modality?(%LLMDB.Model{modalities: modalities}, key) when is_map(modalities) do
    modalities
    |> modality_values(key)
    |> Enum.any?(&(&1 in [:text, "text"]))
  end

  defp text_modality?(%LLMDB.Model{}, _key), do: false

  defp modality_values(modalities, key) do
    case Map.get(modalities, key) || Map.get(modalities, Atom.to_string(key)) do
      values when is_list(values) -> values
      _values -> []
    end
  end

  defp filter_by_query(models, query) do
    normalized_query = normalize_query(query)

    case normalized_query do
      "" -> models
      query -> Enum.filter(models, &model_matches_query?(&1, query))
    end
  end

  defp model_matches_query?(%LLMDB.Model{} = model, query) do
    model
    |> searchable_values()
    |> Enum.any?(&String.contains?(&1, query))
  end

  defp searchable_values(%LLMDB.Model{} = model) do
    [model.id, model.model, model.provider_model_id, model.name, model.family]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_query/1)
  end

  defp option_from_model(%LLMDB.Model{} = model) do
    %{
      "value" => model.id,
      "label" => label(model),
      "description" => description(model)
    }
  end

  defp label(%LLMDB.Model{name: name, id: id}) when is_binary(name) and name != id do
    "#{name} (#{id})"
  end

  defp label(%LLMDB.Model{id: id}), do: id

  defp description(%LLMDB.Model{} = model) do
    [
      model.family,
      token_limit("Context", model, :context),
      token_limit("Output", model, :output),
      release_date(model)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp token_limit(label, %LLMDB.Model{limits: limits}, key) when is_map(limits) do
    case Map.get(limits, key) || Map.get(limits, Atom.to_string(key)) do
      value when is_integer(value) -> "#{label}: #{format_integer(value)}"
      _value -> nil
    end
  end

  defp token_limit(_label, %LLMDB.Model{}, _key), do: nil

  defp release_date(%LLMDB.Model{release_date: release_date}) when is_binary(release_date) do
    "Released: #{release_date}"
  end

  defp release_date(%LLMDB.Model{}), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_query(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_query(value), do: value |> to_string() |> normalize_query()

  defp format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end
end
