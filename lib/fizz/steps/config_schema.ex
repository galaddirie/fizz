defmodule Fizz.Steps.ConfigSchema do
  @moduledoc """
  Type definitions for the declarative step configuration schema system.

  Each step executor defines a `@config_schema` module attribute using standard
  JSON Schema with an optional `"ui"` extension that controls how the field
  is rendered in the frontend config modal.

  ## UI Extension

  The `"ui"` key on a property can contain:

    * `"component"` — which Vue component to render (`"select"`, `"search"`, etc.)
    * `"resolver"` — module implementing `Fizz.Steps.Resolver` for dynamic options
    * `"params"` — parameters forwarded to the resolver (e.g. provider_filter)
    * `"options"` — static list of `%{"label" => ..., "value" => ...}` (alternative to resolver)
    * `"responseConfig"` — mapping config for shaping search results
    * `"slot_kind"`, `"slot_key"`, `"spec"` — slot metadata when `"component"` is `"slot"`

  ## Examples

      # Static select (inferred from `enum`)
      "level" => %{
        "type" => "string",
        "enum" => ["debug", "info", "warn", "error"],
        "default" => "info"
      }

      # Resolver-backed select dropdown
      "credential_ref" => %{
        "type" => "object",
        "title" => "Credential",
        "ui" => %{
          "component" => "select",
          "resolver" => Fizz.Integrations.CredentialsResolver,
          "params" => %{"provider_filter" => ["openai_api_key"]}
        }
      }

      # Resolver-backed search with custom result mapping
      "item" => %{
        "type" => "string",
        "title" => "Item",
        "ui" => %{
          "component" => "search",
          "resolver" => MyApp.MyResolver,
          "params" => %{},
          "responseConfig" => %{
            "mapping" => %{"value" => "id", "label" => "name"}
          }
        }
      }

      # Slot-backed credential field
      "credential_ref" =>
        Fizz.Slots.Field.credential_schema("openai_api_key", :api_key,
          title: "Credential"
        )
  """

  @type ui_config :: %{optional(String.t()) => term()}

  @type schema_property :: %{optional(String.t()) => term()}

  @type config_schema :: %{optional(String.t()) => term()}
end
