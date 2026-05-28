defmodule Fizz.Workflows.Runtime.Payloads do
  @moduledoc false

  def normalize(nil), do: nil

  def normalize(value) when is_map(value) do
    normalize_json(value)
  end

  def normalize(value) do
    %{"value" => normalize_json(value)}
  end

  def normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  def normalize_json(%_{} = value) do
    value
    |> Map.from_struct()
    |> normalize_json()
  end

  def normalize_json(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), normalize_json(nested_value)} end)
  end

  def normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  def normalize_json(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  def normalize_json(nil), do: nil
  def normalize_json(value), do: inspect(value)
end
