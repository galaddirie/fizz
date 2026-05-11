defmodule Fizz.Slots.Field do
  @moduledoc """
  Helpers for declaring slot fields in step config schemas and default configs.

  A slot field has two parts:

    * The **config schema entry** — declares the field's UI rendering and slot
      kind/spec (consumed by the editor).
    * The **default config value** — the slot declaration map that lives in
      step config and, at compile time, becomes a `SlotRef` access plan.
  """

  alias Fizz.Slots.Declaration

  @doc """
  Returns the JSON-shaped schema entry for a credential slot field.
  """
  @spec credential_schema(String.t(), :api_key | :oauth, keyword()) :: map()
  def credential_schema(provider, auth_type, opts \\ [])
      when is_binary(provider) and auth_type in [:api_key, :oauth] do
    title = Keyword.get(opts, :title, "Credential")
    description = Keyword.get(opts, :description)
    slot_key = Keyword.get(opts, :slot_key, "auth")

    base = %{
      "type" => "object",
      "title" => title,
      "ui" => %{
        "component" => "slot",
        "slot_kind" => "credential",
        "slot_key" => slot_key,
        "spec" => %{
          "provider" => provider,
          "auth_type" => Atom.to_string(auth_type)
        }
      }
    }

    if is_binary(description), do: Map.put(base, "description", description), else: base
  end

  @doc """
  Returns the default config value for a credential slot field. This is the
  value persisted in the workflow definition; the compiler turns it into a
  `SlotRef`.
  """
  @spec credential_declaration(String.t(), :api_key | :oauth, keyword()) :: map()
  def credential_declaration(provider, auth_type, opts \\ [])
      when is_binary(provider) and auth_type in [:api_key, :oauth] do
    %{
      "$slot" => true,
      "kind" => "credential",
      "slot_key" => Keyword.get(opts, :slot_key, "auth"),
      "spec" => %{
        "provider" => provider,
        "auth_type" => Atom.to_string(auth_type)
      }
    }
  end

  @doc """
  Returns true if the given value is a slot declaration map.
  """
  @spec slot_declaration?(term()) :: boolean()
  def slot_declaration?(value), do: Declaration.declaration?(value)
end
