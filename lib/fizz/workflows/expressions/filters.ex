defmodule Fizz.Workflows.Expressions.Filters do
  @moduledoc false

  @custom_filter_names ~w(
    json
    parse_json
    to_int
    to_float
    to_bool
    dig
    pluck
    sort_by
    sort_by_desc
    where_eq
    where_ne
    eq
    ne
    gt
    gte
    lt
    lte
    blank
    present
    slugify
  )

  @predicate_filter_names ~w(eq ne gt gte lt lte blank present)

  def custom_filter_names, do: @custom_filter_names
  def predicate_filter_names, do: @predicate_filter_names

  def json(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      _ -> "null"
    end
  end

  def parse_json(value) when is_map(value) or is_list(value), do: value

  def parse_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  def parse_json(_value), do: nil

  def to_int(value) when is_integer(value), do: value
  def to_int(value) when is_float(value), do: trunc(value)
  def to_int(true), do: 1
  def to_int(false), do: 0

  def to_int(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {integer, ""} ->
        integer

      _ ->
        case Float.parse(trimmed) do
          {float, ""} -> trunc(float)
          _ -> nil
        end
    end
  end

  def to_int(_value), do: nil

  def to_float(value) when is_float(value), do: value
  def to_float(value) when is_integer(value), do: value / 1
  def to_float(true), do: 1.0
  def to_float(false), do: 0.0

  def to_float(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {float, ""} ->
        float

      _ ->
        case Integer.parse(trimmed) do
          {integer, ""} -> integer / 1
          _ -> nil
        end
    end
  end

  def to_float(_value), do: nil

  def to_bool(value) when value in [true, false], do: value
  def to_bool(nil), do: false
  def to_bool(value) when is_integer(value) or is_float(value), do: value != 0

  def to_bool(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> false
      "false" -> false
      "0" -> false
      "no" -> false
      "off" -> false
      "n" -> false
      "true" -> true
      "1" -> true
      "yes" -> true
      "on" -> true
      "y" -> true
      _ -> true
    end
  end

  def to_bool(value) when is_list(value), do: value != []
  def to_bool(value) when is_map(value), do: map_size(value) > 0
  def to_bool(_value), do: false

  def dig(value, path) do
    segments = normalize_path(path)

    Enum.reduce_while(segments, value, fn segment, current ->
      case fetch_segment(current, segment) do
        {:ok, next} -> {:cont, next}
        :error -> {:halt, nil}
      end
    end)
  end

  def pluck(values, path) when is_list(values) do
    Enum.map(values, &dig(&1, path))
  end

  def pluck(_values, _path), do: []

  def sort_by(values, path) when is_list(values) do
    Enum.sort_by(values, &sort_key(dig(&1, path)))
  end

  def sort_by(_values, _path), do: []

  def sort_by_desc(values, path) when is_list(values) do
    values
    |> sort_by(path)
    |> Enum.reverse()
  end

  def sort_by_desc(_values, _path), do: []

  def where_eq(values, path, expected) when is_list(values) do
    Enum.filter(values, &(dig(&1, path) == expected))
  end

  def where_eq(_values, _path, _expected), do: []

  def where_ne(values, path, expected) when is_list(values) do
    Enum.filter(values, &(dig(&1, path) != expected))
  end

  def where_ne(_values, _path, _expected), do: []

  def eq(left, right) do
    case coerce_numeric_pair(left, right) do
      {:ok, lhs, rhs} -> lhs == rhs
      :error -> left == right
    end
  end

  def ne(left, right), do: not eq(left, right)

  def gt(left, right), do: compare(left, right, &>/2)
  def gte(left, right), do: compare(left, right, &>=/2)
  def lt(left, right), do: compare(left, right, &</2)
  def lte(left, right), do: compare(left, right, &<=/2)

  def blank(value) when value in [nil, false, []], do: true
  def blank(""), do: true
  def blank(value) when is_binary(value), do: String.trim(value) == ""
  def blank(value) when is_map(value), do: map_size(value) == 0
  def blank(_value), do: false

  def present(value), do: not blank(value)

  def slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp compare(left, right, op) do
    with {:ok, lhs, rhs} <- coerce_numeric_pair(left, right) do
      op.(lhs, rhs)
    else
      :error ->
        cond do
          is_binary(left) and is_binary(right) -> op.(left, right)
          true -> false
        end
    end
  end

  defp coerce_numeric_pair(left, right) do
    with {:ok, lhs} <- to_number(left),
         {:ok, rhs} <- to_number(right) do
      {:ok, lhs, rhs}
    end
  end

  defp to_number(value) when is_integer(value) or is_float(value), do: {:ok, value}

  defp to_number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {float, ""} -> {:ok, float}
      _ -> :error
    end
  end

  defp to_number(_value), do: :error

  defp normalize_path(path) when is_list(path), do: Enum.map(path, &normalize_segment/1)

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.map(&normalize_segment/1)
  end

  defp normalize_path(_path), do: []

  defp normalize_segment(segment) when is_integer(segment), do: segment

  defp normalize_segment(segment) when is_binary(segment) do
    case Integer.parse(segment) do
      {integer, ""} -> integer
      _ -> segment
    end
  end

  defp fetch_segment(list, index) when is_list(list) and is_integer(index) do
    case Enum.at(list, index) do
      nil when index >= length(list) -> :error
      value -> {:ok, value}
    end
  end

  defp fetch_segment(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      true -> :error
    end
  end

  defp fetch_segment(_value, _segment), do: :error

  defp sort_key(value) when is_number(value), do: {0, value}
  defp sort_key(value) when is_binary(value), do: {1, value}
  defp sort_key(value) when is_boolean(value), do: {2, value}
  defp sort_key(nil), do: {3, nil}
  defp sort_key(value), do: {4, inspect(value)}
end
