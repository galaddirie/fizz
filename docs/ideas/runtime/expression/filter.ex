defmodule Fizz.Runtime.Expression.Filters do
  import Kernel, except: [to_string: 1, ceil: 1, floor: 1, abs: 1]

  @moduledoc """
  Custom Liquid filters for workflow expressions.

  These extend Solid's standard filters with workflow-specific operations.
  All filters are designed to be safe and side-effect free.

  ## Available Filters

  ### JSON Operations
  - `json` - Encode value to JSON string
  - `parse_json` - Parse JSON string to value
  - `json_path` - Extract value using JSONPath-like syntax

  ### Type Conversion
  - `to_int` - Convert to integer
  - `to_float` - Convert to float
  - `to_string` - Convert to string
  - `to_bool` - Convert to boolean

  ### Hashing & Encoding
  - `base64_encode` - Base64 encode
  - `base64_decode` - Base64 decode
  - `sha256` - SHA-256 hash (hex)
  - `md5` - MD5 hash (hex)
  - `hmac_sha256` - HMAC-SHA256 with secret

  ### Data Manipulation
  - `dig` - Deep access with dot notation path
  - `pluck` - Extract field from list of maps
  - `group_by` - Group list by field
  - `sort_by` - Sort list by field
  - `where_eq` - Filter list where field equals value
  - `where_ne` - Filter list where field not equals value
  - `unique_by` - Unique by field
  - `index_by` - Convert list to map indexed by field

  ### String Operations
  - `slugify` - Convert to URL slug
  - `truncate_words` - Truncate to N words
  - `extract` - Regex extract
  - `match` - Regex match test

  ### Math
  - `abs` - Absolute value
  - `ceil` - Ceiling
  - `floor` - Floor
  - `round_to` - Round to N decimals
  - `clamp` - Clamp between min and max

  ### Date/Time
  - `parse_date` - Parse date string
  - `format_date` - Format date
  - `add_days` / `add_hours` / `add_minutes` - Date arithmetic

  ## Usage

      {{ json.data | json }}
      {{ json.items | pluck: "name" }}
      {{ json.nested | dig: "a.b.c" }}
      {{ json.password | sha256 }}
  """

  # ============================================================================
  # JSON Operations
  # ============================================================================

  @doc "Encode value as JSON string"
  def json(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _} -> ""
    end
  end

  @doc "Parse JSON string to value"
  def parse_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  def parse_json(_), do: nil

  # ============================================================================
  # Type Conversions
  # ============================================================================

  @doc "Convert to integer"
  def to_int(value) when is_integer(value), do: value
  def to_int(value) when is_float(value), do: trunc(value)

  def to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  def to_int(true), do: 1
  def to_int(false), do: 0
  def to_int(_), do: 0

  @doc "Convert to float"
  def to_float(value) when is_float(value), do: value
  def to_float(value) when is_integer(value), do: value * 1.0

  def to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  def to_float(_), do: 0.0

  @doc "Convert to string"
  def to_string(value) when is_binary(value), do: value
  def to_string(value) when is_atom(value), do: Atom.to_string(value)
  def to_string(value) when is_number(value), do: Kernel.to_string(value)
  def to_string(value) when is_list(value) or is_map(value), do: json(value)
  def to_string(nil), do: ""
  def to_string(value), do: inspect(value)

  @doc "Convert to boolean"
  def to_bool(nil), do: false
  def to_bool(false), do: false
  def to_bool(0), do: false
  def to_bool(""), do: false
  def to_bool("false"), do: false
  def to_bool("0"), do: false
  def to_bool([]), do: false
  def to_bool(%{} = map) when map_size(map) == 0, do: false
  def to_bool(_), do: true

  # ============================================================================
  # Hashing & Encoding
  # ============================================================================

  @doc "Base64 encode"
  def base64_encode(value) when is_binary(value), do: Base.encode64(value)
  def base64_encode(value), do: value |> to_string() |> Base.encode64()

  @doc "Base64 decode"
  def base64_decode(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> decoded
      :error -> value
    end
  end

  def base64_decode(value), do: value

  @doc "SHA-256 hash (hex encoded)"
  def sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  def sha256(value), do: value |> to_string() |> sha256()

  @doc "MD5 hash (hex encoded)"
  def md5(value) when is_binary(value) do
    :crypto.hash(:md5, value) |> Base.encode16(case: :lower)
  end

  def md5(value), do: value |> to_string() |> md5()

  @doc "HMAC-SHA256 with secret"
  def hmac_sha256(value, secret) when is_binary(value) and is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, value) |> Base.encode16(case: :lower)
  end

  def hmac_sha256(value, secret), do: hmac_sha256(to_string(value), to_string(secret))

  # ============================================================================
  # Data Manipulation
  # ============================================================================

  @doc "Deep access with dot notation: {{ data | dig: 'a.b.c' }}"
  def dig(value, path) when is_binary(path) do
    keys = String.split(path, ".")
    get_nested(value, keys)
  end

  def dig(value, _), do: value

  defp get_nested(value, []), do: value
  defp get_nested(nil, _), do: nil

  defp get_nested(value, [key | rest]) when is_map(value) do
    next = get_map_value(value, key)
    get_nested(next, rest)
  end

  defp get_nested(value, [key | rest]) when is_list(value) do
    case Integer.parse(key) do
      {index, ""} -> get_nested(Enum.at(value, index), rest)
      _ -> nil
    end
  end

  defp get_nested(_, _), do: nil

  defp get_map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || get_map_value_by_atom(map, key)
  end

  defp get_map_value_by_atom(map, key) do
    case safe_existing_atom(key) do
      {:ok, atom} -> Map.get(map, atom)
      :error -> nil
    end
  end

  defp safe_existing_atom(key) when is_binary(key) do
    try do
      {:ok, String.to_existing_atom(key)}
    rescue
      ArgumentError -> :error
    end
  end

  defp safe_existing_atom(_), do: :error

  @doc "Extract field from list of maps: {{ items | pluck: 'name' }}"
  def pluck(list, field) when is_list(list) and is_binary(field) do
    Enum.map(list, fn item ->
      if is_map(item), do: get_map_value(item, field), else: nil
    end)
  end

  def pluck(value, _), do: value

  @doc "Group list by field: {{ items | group_by: 'category' }}"
  def group_by(list, field) when is_list(list) and is_binary(field) do
    Enum.group_by(list, fn item ->
      if is_map(item), do: get_map_value(item, field), else: nil
    end)
  end

  def group_by(value, _), do: value

  @doc "Sort list by field: {{ items | sort_by: 'name' }}"
  def sort_by(list, field) when is_list(list) and is_binary(field) do
    Enum.sort_by(list, fn item ->
      if is_map(item), do: get_map_value(item, field), else: nil
    end)
  end

  def sort_by(value, _), do: value

  @doc "Sort list by field descending: {{ items | sort_by_desc: 'count' }}"
  def sort_by_desc(list, field) when is_list(list) and is_binary(field) do
    Enum.sort_by(
      list,
      fn item ->
        if is_map(item), do: get_map_value(item, field), else: nil
      end,
      :desc
    )
  end

  def sort_by_desc(value, _), do: value

  @doc "Filter where field equals value: {{ items | where_eq: 'status', 'active' }}"
  def where_eq(list, field, value) when is_list(list) and is_binary(field) do
    Enum.filter(list, fn item ->
      if is_map(item) do
        item_value = get_map_value(item, field)
        item_value == value
      else
        false
      end
    end)
  end

  def where_eq(value, _, _), do: value

  @doc "Filter where field not equals value: {{ items | where_ne: 'status', 'deleted' }}"
  def where_ne(list, field, value) when is_list(list) and is_binary(field) do
    Enum.filter(list, fn item ->
      if is_map(item) do
        item_value = get_map_value(item, field)
        item_value != value
      else
        true
      end
    end)
  end

  def where_ne(value, _, _), do: value

  @doc "Unique by field: {{ items | unique_by: 'id' }}"
  def unique_by(list, field) when is_list(list) and is_binary(field) do
    Enum.uniq_by(list, fn item ->
      if is_map(item), do: get_map_value(item, field), else: item
    end)
  end

  def unique_by(value, _), do: value

  @doc "Index list by field: {{ items | index_by: 'id' }}"
  def index_by(list, field) when is_list(list) and is_binary(field) do
    Map.new(list, fn item ->
      key =
        if is_map(item), do: get_map_value(item, field), else: nil

      {key, item}
    end)
  end

  def index_by(value, _), do: value

  @doc "Get keys from map: {{ data | keys }}"
  def keys(value) when is_map(value), do: Map.keys(value)
  def keys(_), do: []

  @doc "Get values from map: {{ data | values }}"
  def values(value) when is_map(value), do: Map.values(value)
  def values(_), do: []

  @doc "Merge maps: {{ data | merge: other }}"
  def merge(value, other) when is_map(value) and is_map(other), do: Map.merge(value, other)
  def merge(value, _), do: value

  @doc "Pick specific keys: {{ data | pick: 'name,email' }}"
  def pick(value, keys_str) when is_map(value) and is_binary(keys_str) do
    keys = keys_str |> String.split(",") |> Enum.map(&String.trim/1)
    Map.take(value, keys)
  end

  def pick(value, _), do: value

  @doc "Omit specific keys: {{ data | omit: 'password,secret' }}"
  def omit(value, keys_str) when is_map(value) and is_binary(keys_str) do
    keys = keys_str |> String.split(",") |> Enum.map(&String.trim/1)
    Map.drop(value, keys)
  end

  def omit(value, _), do: value

  # ============================================================================
  # String Operations
  # ============================================================================

  @doc "Convert to URL slug: {{ title | slugify }}"
  def slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  def slugify(value), do: value |> to_string() |> slugify()

  @doc "Truncate to N words: {{ text | truncate_words: 10 }}"
  def truncate_words(value, count) when is_binary(value) and is_integer(count) do
    words = String.split(value)

    if length(words) > count do
      words |> Enum.take(count) |> Enum.join(" ") |> Kernel.<>("...")
    else
      value
    end
  end

  def truncate_words(value, count) when is_binary(count), do: truncate_words(value, to_int(count))
  def truncate_words(value, _), do: value

  @doc "Regex extract: {{ text | extract: '\\d+' }}"
  def extract(value, pattern) when is_binary(value) and is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        case Regex.run(regex, value) do
          [match | _] -> match
          nil -> ""
        end

      {:error, _} ->
        ""
    end
  end

  def extract(value, _), do: value

  @doc "Regex match test: {{ text | match: '^\\d+$' }}"
  def match(value, pattern) when is_binary(value) and is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end

  def match(_, _), do: false

  @doc "Pad left: {{ num | pad_left: 5, '0' }}"
  def pad_left(value, length, pad \\ " ")

  def pad_left(value, length, pad) when is_binary(value) and is_integer(length) do
    String.pad_leading(value, length, pad)
  end

  def pad_left(value, length, pad), do: value |> to_string() |> pad_left(to_int(length), pad)

  @doc "Pad right: {{ text | pad_right: 20 }}"
  def pad_right(value, length, pad \\ " ")

  def pad_right(value, length, pad) when is_binary(value) and is_integer(length) do
    String.pad_trailing(value, length, pad)
  end

  def pad_right(value, length, pad), do: value |> to_string() |> pad_right(to_int(length), pad)

  # ============================================================================
  # Math
  # ============================================================================

  @doc "Absolute value: {{ num | abs }}"
  def abs(value) when is_number(value), do: Kernel.abs(value)
  def abs(value), do: value |> to_float() |> Kernel.abs()

  @doc "Ceiling: {{ num | ceil }}"
  def ceil(value) when is_number(value), do: Float.ceil(value * 1.0) |> trunc()
  def ceil(value), do: value |> to_float() |> ceil()

  @doc "Floor: {{ num | floor }}"
  def floor(value) when is_number(value), do: Float.floor(value * 1.0) |> trunc()
  def floor(value), do: value |> to_float() |> floor()

  @doc "Round to N decimals: {{ num | round_to: 2 }}"
  def round_to(value, decimals) when is_number(value) and is_integer(decimals) do
    Float.round(value * 1.0, decimals)
  end

  def round_to(value, decimals), do: round_to(to_float(value), to_int(decimals))

  @doc "Clamp between min and max: {{ num | clamp: 0, 100 }}"
  def clamp(value, min_val, max_val) do
    value = to_float(value)
    min_val = to_float(min_val)
    max_val = to_float(max_val)

    value |> max(min_val) |> min(max_val)
  end

  # ============================================================================
  # Date/Time
  # ============================================================================

  @doc "Format date: {{ date | format_date: '%Y-%m-%d' }}"
  def format_date(value, format) when is_binary(format) do
    case parse_datetime(value) do
      {:ok, datetime} -> Calendar.strftime(datetime, format)
      :error -> value
    end
  end

  def format_date(value, _), do: value

  @doc "Add days: {{ date | add_days: 7 }}"
  def add_days(value, days) when is_integer(days) do
    case parse_datetime(value) do
      {:ok, datetime} ->
        datetime
        |> DateTime.add(days * 86400, :second)
        |> DateTime.to_iso8601()

      :error ->
        value
    end
  end

  def add_days(value, days), do: add_days(value, to_int(days))

  @doc "Add hours: {{ date | add_hours: 2 }}"
  def add_hours(value, hours) when is_integer(hours) do
    case parse_datetime(value) do
      {:ok, datetime} ->
        datetime
        |> DateTime.add(hours * 3600, :second)
        |> DateTime.to_iso8601()

      :error ->
        value
    end
  end

  def add_hours(value, hours), do: add_hours(value, to_int(hours))

  @doc "Add minutes: {{ date | add_minutes: 30 }}"
  def add_minutes(value, minutes) when is_integer(minutes) do
    case parse_datetime(value) do
      {:ok, datetime} ->
        datetime
        |> DateTime.add(minutes * 60, :second)
        |> DateTime.to_iso8601()

      :error ->
        value
    end
  end

  def add_minutes(value, mins), do: add_minutes(value, to_int(mins))

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp parse_datetime(_), do: :error

  # ============================================================================
  # Utility
  # ============================================================================

  @doc "Return value if truthy, otherwise default: {{ val | default: 'N/A' }}"
  def default(nil, default_value), do: default_value
  def default(false, default_value), do: default_value
  def default("", default_value), do: default_value
  def default([], default_value), do: default_value
  def default(%{} = map, default_value) when map_size(map) == 0, do: default_value
  def default(value, _), do: value

  @doc "Coalesce - return first non-nil value: {{ val | coalesce: fallback1, fallback2 }}"
  def coalesce(nil, fallback), do: fallback
  def coalesce(value, _), do: value
end
