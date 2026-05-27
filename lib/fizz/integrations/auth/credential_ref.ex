defmodule Fizz.Integrations.Auth.CredentialRef do
  @moduledoc """
  Helpers for validating and normalizing workflow credential references.

  Credential refs are metadata-only maps persisted in workflow step config and
  execution payloads. Secret values are never included.
  """

  @type auth_type :: :api_key | :oauth

  @type t :: map()

  @spec normalize(map() | nil) :: {:ok, t()} | {:error, term()}
  def normalize(nil), do: {:error, :credential_ref_required}

  def normalize(ref) when is_map(ref) do
    with {:ok, id} <- required_string(ref, :id),
         {:ok, provider} <- required_string(ref, :provider),
         {:ok, auth_type} <- normalize_auth_type(ref),
         {:ok, owner_user_id} <- required_string(ref, :owner_user_id) do
      {:ok,
       %{
         "id" => id,
         "provider" => provider,
         "auth_type" => auth_type,
         "owner_user_id" => owner_user_id
       }}
    end
  end

  def normalize(_ref), do: {:error, :invalid_credential_ref}

  @spec normalize_for_provider(map() | nil, String.t(), auth_type()) ::
          {:ok, t()} | {:error, term()}
  def normalize_for_provider(ref, provider, auth_type)
      when is_binary(provider) and auth_type in [:api_key, :oauth] do
    with {:ok, normalized_ref} <- normalize(ref),
         :ok <- ensure_provider(normalized_ref, provider),
         :ok <- ensure_auth_type(normalized_ref, auth_type) do
      {:ok, normalized_ref}
    end
  end

  @spec ensure_owner(map() | nil, String.t()) :: :ok | {:error, term()}
  def ensure_owner(nil, _owner_user_id), do: {:error, :credential_ref_required}

  def ensure_owner(ref, owner_user_id) when is_map(ref) and is_binary(owner_user_id) do
    with {:ok, normalized_ref} <- normalize(ref) do
      if normalized_ref["owner_user_id"] == owner_user_id do
        :ok
      else
        {:error, :credential_ref_owner_mismatch}
      end
    end
  end

  def ensure_owner(_ref, _owner_user_id), do: {:error, :invalid_credential_ref}

  @spec id(map() | nil) :: {:ok, String.t()} | {:error, term()}
  def id(nil), do: {:error, :credential_ref_required}

  def id(ref) when is_map(ref) do
    with {:ok, normalized_ref} <- normalize(ref) do
      {:ok, normalized_ref["id"]}
    end
  end

  def id(_ref), do: {:error, :invalid_credential_ref}

  @spec to_atom_auth_type(String.t() | atom()) ::
          {:ok, auth_type()} | {:error, :invalid_auth_type}
  def to_atom_auth_type(:api_key), do: {:ok, :api_key}
  def to_atom_auth_type(:oauth), do: {:ok, :oauth}
  def to_atom_auth_type("api_key"), do: {:ok, :api_key}
  def to_atom_auth_type("oauth"), do: {:ok, :oauth}
  def to_atom_auth_type(_auth_type), do: {:error, :invalid_auth_type}

  defp ensure_provider(%{"provider" => provider}, expected_provider)
       when provider == expected_provider,
       do: :ok

  defp ensure_provider(_ref, _expected_provider), do: {:error, :credential_ref_provider_mismatch}

  defp ensure_auth_type(%{"auth_type" => auth_type}, expected_auth_type) do
    if auth_type == Atom.to_string(expected_auth_type) do
      :ok
    else
      {:error, :credential_ref_auth_type_mismatch}
    end
  end

  defp normalize_auth_type(ref) do
    ref
    |> fetch_field(:auth_type)
    |> to_atom_auth_type()
    |> case do
      {:ok, auth_type} -> {:ok, Atom.to_string(auth_type)}
      {:error, :invalid_auth_type} -> {:error, :invalid_credential_ref_auth_type}
    end
  end

  defp required_string(ref, field) when is_map(ref) and is_atom(field) do
    case fetch_field(ref, field) do
      value when is_binary(value) ->
        normalized = String.trim(value)

        if normalized == "" do
          {:error, {:missing_field, field}}
        else
          {:ok, normalized}
        end

      _ ->
        {:error, {:missing_field, field}}
    end
  end

  defp fetch_field(map, field) when is_map(map) and is_atom(field) do
    Map.get(map, field) || Map.get(map, Atom.to_string(field))
  end
end
