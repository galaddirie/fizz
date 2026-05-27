defmodule Fizz.Steps.ConfigSchema do
  @moduledoc """
  Type definitions for the declarative step configuration schema system.

  Each step executor defines a `@config_schema` module attribute using standard
  JSON Schema with an optional `"ui"` extension that controls how the field
  is rendered in the frontend config modal.

  ## UI Extension

  The `"ui"` key on a property can contain:

    * `"component"` — which Vue component to render (`"select"`, `"search"`, etc.)
    * `"resolver"` — module with `resolve/1` for dynamic options
    * `"params"` — parameters forwarded to the resolver (e.g. provider_filter)
    * `"options"` — static list of `%{"label" => ..., "value" => ...}` (alternative to resolver)
    * `"responseConfig"` — mapping config for shaping search results
    * `"provider"`, `"auth_type"`, `"requirement_key"` — credential metadata when `"component"` is `"credential"`

  ## Examples

      # Static select (inferred from `enum`)
      "level" => %{
        "type" => "string",
        "enum" => ["debug", "info", "warn", "error"],
        "default" => "info"
      }

      # Credential field
      "credential_ref" => %{
        "type" => "object",
        "title" => "Credential",
        "ui" => %{
          "component" => "credential",
          "provider" => "openai_api_key",
          "auth_type" => "api_key",
          "requirement_key" => "auth"
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

      # Credential field helper
      credential_field =
        Fizz.Fields.credential("openai_api_key", :api_key,
          key: "credential_ref",
          label: "Credential"
        )

      "credential_ref" => Fizz.Fields.to_schema_property(credential_field)
  """

  @type ui_config :: %{optional(String.t()) => term()}

  @type schema_property :: %{optional(String.t()) => term()}

  @type config_schema :: %{optional(String.t()) => term()}
end
