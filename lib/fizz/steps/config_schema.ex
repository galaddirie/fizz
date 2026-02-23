defmodule Fizz.Steps.ConfigSchema do
  @moduledoc """
  Type definitions for the declarative step configuration schema system.

  Each step executor defines a `@config_schema` module attribute using standard
  JSON Schema with an optional `"ui"` extension that controls how the field
  is rendered in the frontend config modal.

  ## UI Extension

  The `"ui"` key on a property can contain:

    * `"component"` — which Vue component to render (`"select"`, `"search"`, etc.)
    * `"resolver"` — name of a `Fizz.Steps.FieldResolver` resolver for dynamic options
    * `"params"` — parameters forwarded to the resolver (e.g. provider_filter)
    * `"options"` — static list of `%{"label" => ..., "value" => ...}` (alternative to resolver)
    * `"responseConfig"` — mapping config for shaping search results

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
          "resolver" => "credentials",
          "params" => %{"provider_filter" => ["openai_api_key"]}
        }
      }

      # Resolver-backed search with custom result mapping
      "item" => %{
        "type" => "string",
        "title" => "Item",
        "ui" => %{
          "component" => "search",
          "resolver" => "my_resolver",
          "params" => %{},
          "responseConfig" => %{
            "mapping" => %{"value" => "id", "label" => "name"}
          }
        }
      }
  """

  @type ui_component :: String.t()

  @type ui_config :: %{
          optional(String.t()) => term(),
          optional("component") => ui_component(),
          optional("resolver") => String.t(),
          optional("params") => map(),
          optional("options") => [%{String.t() => term()}],
          optional("responseConfig") => %{optional(String.t()) => term()}
        }

  @type schema_property :: %{
          optional(String.t()) => term(),
          optional("type") => String.t(),
          optional("title") => String.t(),
          optional("description") => String.t(),
          optional("default") => term(),
          optional("format") => String.t(),
          optional("enum") => [term()],
          optional("ui") => ui_config()
        }

  @type config_schema :: %{
          optional(String.t()) => term(),
          optional("type") => String.t(),
          optional("required") => [String.t()],
          optional("properties") => %{String.t() => schema_property()}
        }
end
