defmodule Fizz.Credentials.Field do
  @moduledoc """
  Helpers for declaring credential fields in step config schemas and default configs.

  A credential field has two parts:

    * The **config schema entry** — declares the field's UI rendering and
      provider/auth contract (consumed by the editor).
    * The **default config value** — the credential declaration map that lives in
    step config and, at compile time, becomes a `CredentialRef` access plan.
  """

  alias Fizz.Credentials.Declaration

  @doc """
  Returns the JSON-shaped schema entry for a credential field.
  """
  @spec credential_schema(String.t(), :api_key | :oauth, keyword()) :: map()
  def credential_schema(provider, auth_type, opts \\ [])
      when is_binary(provider) and auth_type in [:api_key, :oauth] do
    title = Keyword.get(opts, :title, "Credential")
    description = Keyword.get(opts, :description)
    requirement_key = Keyword.get(opts, :requirement_key, "auth")

    base = %{
      "type" => "object",
      "title" => title,
      "ui" => %{
        "component" => "credential",
        "requirement_key" => requirement_key,
        "provider" => provider,
        "auth_type" => Atom.to_string(auth_type)
      }
    }

    if is_binary(description), do: Map.put(base, "description", description), else: base
  end

  @doc """
  Returns the default config value for a credential field. This is the
  value persisted in the workflow definition; the compiler turns it into a
  `CredentialRef`.
  """
  @spec credential_declaration(String.t(), :api_key | :oauth, keyword()) :: map()
  def credential_declaration(provider, auth_type, opts \\ [])
      when is_binary(provider) and auth_type in [:api_key, :oauth] do
    %{
      "$credential" => true,
      "requirement_key" => Keyword.get(opts, :requirement_key, "auth"),
      "provider" => provider,
      "auth_type" => Atom.to_string(auth_type)
    }
  end

  @doc """
  Returns true if the given value is a credential declaration map.
  """
  @spec declaration?(term()) :: boolean()
  def declaration?(value), do: Declaration.declaration?(value)
end
