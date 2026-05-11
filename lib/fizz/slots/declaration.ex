defmodule Fizz.Slots.Declaration do
  @moduledoc """
  Helpers for slot declaration maps embedded in workflow step configs.

  Authored workflow configs store declarations such as:

      %{
        "$slot" => true,
        "kind" => "credential",
        "slot_key" => "auth",
        "spec" => %{"provider" => "openai_api_key", "auth_type" => "api_key"}
      }

  This module is the canonical place for identifying, walking, normalizing, and
  validating those declaration maps.
  """

  alias Fizz.Slots.Registry

  @type path :: [String.t()]
  @type normalized :: %{
          kind: String.t(),
          slot_key: String.t(),
          spec: map()
        }

  @type walked :: %{
          path: path(),
          declaration: map()
        }

  @doc """
  Returns true when `value` is a slot declaration map.
  """
  @spec declaration?(term()) :: boolean()
  def declaration?(value) when is_map(value) do
    Map.get(value, "$slot") == true or Map.get(value, :"$slot") == true
  end

  def declaration?(_value), do: false

  @doc """
  Walks a nested term and returns every slot declaration with its field path.
  """
  @spec walk(term()) :: [walked()]
  def walk(value), do: do_walk(value, [])

  @doc """
  Normalizes a slot declaration to string keys needed by compiler/runtime code.
  """
  @spec normalize(term()) :: {:ok, normalized()} | {:error, term()}
  def normalize(value) when is_map(value) do
    with true <- declaration?(value),
         {:ok, kind} <- required_string(value, "kind"),
         {:ok, slot_key} <- required_string(value, "slot_key"),
         {:ok, spec} <- fetch_spec(value) do
      {:ok, %{kind: kind, slot_key: slot_key, spec: spec}}
    else
      false -> {:error, :not_a_slot_declaration}
      {:error, _reason} = error -> error
    end
  end

  def normalize(_value), do: {:error, :not_a_slot_declaration}

  @doc """
  Validates a slot declaration and its registered resolver-specific spec.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(value) do
    with {:ok, %{kind: kind, spec: spec}} <- normalize(value),
         {:ok, module} <- fetch_registered_kind(kind),
         :ok <- validate_spec(module, spec) do
      :ok
    else
      {:error, {:missing_field, field}} ->
        {:error, "slot is missing #{field}"}

      {:error, :not_a_slot_declaration} ->
        {:error, "slot declaration is invalid"}

      {:error, {:unregistered_kind, kind}} ->
        {:error, "slot kind \"#{kind}\" is not registered"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Formats a declaration path for issue reporting.
  """
  @spec format_path(path()) :: String.t() | nil
  def format_path([]), do: nil
  def format_path(path), do: Enum.join(path, ".")

  defp do_walk(value, path) when is_map(value) do
    if declaration?(value) do
      [%{path: path, declaration: value}]
    else
      Enum.flat_map(value, fn {key, nested_value} ->
        do_walk(nested_value, path ++ [to_string(key)])
      end)
    end
  end

  defp do_walk(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      do_walk(value, path ++ [Integer.to_string(index)])
    end)
  end

  defp do_walk(_value, _path), do: []

  defp fetch_registered_kind(kind) do
    case Registry.fetch(kind) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unregistered_kind, kind}}
    end
  end

  defp validate_spec(module, spec) do
    if function_exported?(module, :validate_spec, 1) do
      module.validate_spec(spec)
    else
      :ok
    end
  end

  defp required_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_field, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp fetch_spec(map) do
    case fetch_value(map, "spec") do
      spec when is_map(spec) -> {:ok, spec}
      _ -> {:error, {:missing_field, "spec"}}
    end
  end

  defp fetch_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end
end
