defmodule Fizz.Workflows.StepExecutionTrace do
  @moduledoc false

  @splitter_fan_out_suffix "__fan_out"

  @spec logical_step_id(atom() | String.t() | term(), map() | nil) :: {:ok, String.t()} | :error
  def logical_step_id(name, step_type_by_id \\ nil)

  def logical_step_id(name, step_type_by_id) when is_atom(name) do
    name
    |> Atom.to_string()
    |> logical_step_id(step_type_by_id)
  end

  def logical_step_id(name, step_type_by_id) when is_binary(name) do
    if String.contains?(name, "__") do
      :error
    else
      validate_step_id(name, step_type_by_id)
    end
  end

  def logical_step_id(_name, _step_type_by_id), do: :error

  @spec splitter_fan_out_step_id(atom() | String.t() | term(), map() | nil) ::
          {:ok, String.t()} | :error
  def splitter_fan_out_step_id(name, step_type_by_id \\ nil)

  def splitter_fan_out_step_id(name, step_type_by_id) when is_atom(name) do
    name
    |> Atom.to_string()
    |> splitter_fan_out_step_id(step_type_by_id)
  end

  def splitter_fan_out_step_id(name, step_type_by_id) when is_binary(name) do
    if String.ends_with?(name, @splitter_fan_out_suffix) do
      name
      |> String.trim_trailing(@splitter_fan_out_suffix)
      |> validate_splitter_step_id(step_type_by_id)
    else
      :error
    end
  end

  def splitter_fan_out_step_id(_name, _step_type_by_id), do: :error

  @spec fact_item_index(term()) :: non_neg_integer() | nil
  def fact_item_index(%{meta: meta}) when is_map(meta) do
    meta
    |> fetch_meta_value(:item_index)
    |> normalize_non_neg_integer()
  end

  def fact_item_index(_fact), do: nil

  @spec fact_items_total(term()) :: pos_integer() | nil
  def fact_items_total(%{meta: meta}) when is_map(meta) do
    meta
    |> fetch_meta_value(:items_total)
    |> normalize_positive_integer()
  end

  def fact_items_total(_fact), do: nil

  @spec fact_iteration_metadata(term()) :: %{
          item_index: non_neg_integer() | nil,
          items_total: pos_integer() | nil
        }
  def fact_iteration_metadata(fact) do
    %{
      item_index: fact_item_index(fact),
      items_total: fact_items_total(fact)
    }
  end

  defp validate_splitter_step_id(step_id, nil) when is_binary(step_id), do: {:ok, step_id}

  defp validate_splitter_step_id(step_id, step_type_by_id) when is_map(step_type_by_id) do
    case Map.get(step_type_by_id, step_id) do
      "splitter" -> {:ok, step_id}
      _other -> :error
    end
  end

  defp validate_splitter_step_id(_step_id, _step_type_by_id), do: :error

  defp validate_step_id(step_id, nil) when is_binary(step_id), do: {:ok, step_id}

  defp validate_step_id(step_id, step_type_by_id) when is_map(step_type_by_id) do
    if Map.has_key?(step_type_by_id, step_id) do
      {:ok, step_id}
    else
      :error
    end
  end

  defp validate_step_id(_step_id, _step_type_by_id), do: :error

  defp fetch_meta_value(meta, key) do
    case Map.fetch(meta, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(meta, Atom.to_string(key))
    end
  end

  defp normalize_non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_integer(_value), do: nil

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value), do: nil
end
