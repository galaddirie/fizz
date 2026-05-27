defmodule Fizz.Credentials.Declaration do
  @moduledoc """
  Helpers for credential declaration maps embedded in workflow step configs.

  Authored workflow configs store declarations such as:

      %{
        "$credential" => true,
        "requirement_key" => "auth",
        "provider" => "openai_api_key",
        "auth_type" => "api_key"
      }

  This module is the canonical place for identifying, walking, normalizing, and
  validating those declaration maps.
  """

  @type path :: [String.t()]
  @type normalized :: %{
          requirement_key: String.t(),
          provider: String.t(),
          auth_type: String.t()
        }

  @type walked :: %{
          path: path(),
          declaration: map()
        }

  @doc """
  Returns true when `value` is a credential declaration map.
  """
  @spec declaration?(term()) :: boolean()
  def declaration?(value) when is_map(value) do
    Map.get(value, "$credential") == true or Map.get(value, :"$credential") == true
  end

  def declaration?(_value), do: false

  @doc """
  Walks a nested term and returns every credential declaration with its field path.
  """
  @spec walk(term()) :: [walked()]
  def walk(value), do: do_walk(value, [])

  @doc """
  Normalizes a credential declaration to string keys needed by compiler/runtime code.
  """
  @spec normalize(term()) :: {:ok, normalized()} | {:error, term()}
  def normalize(value) when is_map(value) do
    with true <- declaration?(value),
         {:ok, requirement_key} <- required_string(value, "requirement_key"),
         {:ok, provider} <- required_string(value, "provider"),
         {:ok, auth_type} <- required_string(value, "auth_type"),
         :ok <- validate_auth_type(auth_type) do
      {:ok, %{requirement_key: requirement_key, provider: provider, auth_type: auth_type}}
    else
      false -> {:error, :not_a_credential_declaration}
      {:error, _reason} = error -> error
    end
  end

  def normalize(_value), do: {:error, :not_a_credential_declaration}

  @doc """
  Validates a credential declaration.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(value) do
    with {:ok, _declaration} <- normalize(value) do
      :ok
    else
      {:error, {:missing_field, field}} ->
        {:error, "credential is missing #{field}"}

      {:error, :not_a_credential_declaration} ->
        {:error, "credential declaration is invalid"}

      {:error, :invalid_auth_type} ->
        {:error, "credential auth_type must be api_key or oauth"}

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

  defp validate_auth_type(auth_type) when auth_type in ["api_key", "oauth"], do: :ok
  defp validate_auth_type(_auth_type), do: {:error, :invalid_auth_type}

  defp fetch_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end
end
