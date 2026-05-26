defmodule Fizz.Steps.Executors.GoogleSheetsAppendRow do
  @moduledoc """
  Appends a row to a Google Sheet.
  """

  use Fizz.Steps.Definition,
    id: "google_sheets_append_row",
    name: "Google Sheets — Append Row",
    category: "Documents",
    description: "Append a new row of data to a Google Sheet",
    icon: "/images/google_sheets.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Google.Sheets.Actions.AppendRow
  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Slots.CredentialSlot

  @credential_slot CredentialSlot.oauth(GoogleOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialSlot.declaration(@credential_slot)
  }

  @spreadsheet_locator %{
    "kind" => "google_sheets.spreadsheet",
    "value_key" => "spreadsheet_id"
  }
  @values_depends_on ["credential_ref", "spreadsheet_id", "sheet_name", "table_id"]
  @row_values_mapper %{
    "kind" => "google_sheets.row_values",
    "fields" => %{
      "primary_resource" => "sheet_name",
      "schema_resource" => "table_id"
    },
    "labels" => %{
      "primary_resource" => "Sheet",
      "schema_resource" => "Table",
      "no_primary_resource" => "No sheet",
      "no_schema_resource" => "No table",
      "selected_schema_fallback" => "No table selected",
      "schema_locked" => "Schema locked",
      "freeform" => "Freeform",
      "empty_state" => "Flexible columns",
      "lookup_loading" => "Loading table schema; editing stays available",
      "lookup_failed" => "Table lookup failed; editing stays available",
      "schema_unavailable" => "Table schema unavailable; editing stays available",
      "refresh_idle" => "Refresh sheets and tables",
      "refresh_loading" => "Refreshing resource metadata"
    },
    "lookups" => %{
      "primary_resource" => %{
        "mode" => "sheets",
        "params" => %{
          "credential_ref" => "credential_ref",
          "spreadsheet_id" => "spreadsheet_id"
        }
      },
      "schema_resource" => %{
        "mode" => "tables",
        "params" => %{
          "credential_ref" => "credential_ref",
          "spreadsheet_id" => "spreadsheet_id"
        },
        "parent_option_field" => "sheet_name"
      }
    },
    "errors" => %{
      "primary_resource" => %{
        "no_google_credential" => "Connect a Google account to load this spreadsheet's sheets.",
        "unauthorized" => "Your Google account does not have access to this spreadsheet.",
        "forbidden" => "Your Google account does not have access to this spreadsheet.",
        "spreadsheet_not_found" =>
          "Couldn't find that spreadsheet. Double-check the Spreadsheet ID.",
        "invalid_range_or_sheet" =>
          "Couldn't read that sheet. Make sure the Sheet Name matches the tab in Google Sheets exactly.",
        "rate_limited" => "Google rate-limited the lookup. Try again in a moment.",
        "fetch_failed" => "Could not load sheets from this spreadsheet."
      },
      "schema_resource" => %{
        "no_google_credential" => "Connect a Google account to load this spreadsheet's tables.",
        "unauthorized" => "Your Google account does not have access to this spreadsheet.",
        "forbidden" => "Your Google account does not have access to this spreadsheet.",
        "spreadsheet_not_found" =>
          "Couldn't find that spreadsheet. Double-check the Spreadsheet ID.",
        "rate_limited" => "Google rate-limited the lookup. Try again in a moment.",
        "fetch_failed" => "Could not load tables from this spreadsheet."
      }
    }
  }

  @config_schema %{
    "type" => "object",
    "required" => ["credential_ref", "spreadsheet_id", "values"],
    "properties" => %{
      "credential_ref" => CredentialSlot.schema(@credential_slot, title: "Google Account"),
      "spreadsheet_id" => %{
        "type" => "string",
        "title" => "Spreadsheet ID",
        "resource_locator" => @spreadsheet_locator,
        "ui" => %{
          "component" => "resource_locator",
          "resource_locator" => @spreadsheet_locator
        }
      },
      "sheet_name" => %{
        "type" => "string",
        "title" => "Sheet Name",
        "default" => "",
        "ui" => %{"component" => "hidden"}
      },
      "table_id" => %{
        "type" => "string",
        "title" => "Table ID",
        "default" => "",
        "ui" => %{"component" => "hidden"}
      },
      "values" => %{
        "type" => "object",
        "title" => "Row Values",
        "description" => "Map a value to each column in your sheet.",
        "depends_on" => @values_depends_on,
        "display" => %{
          "empty_state" => "Flexible columns",
          "schema_state" => "Schema locked"
        },
        "resource_mapper" => @row_values_mapper,
        "ui" => %{
          "component" => "resource_mapper",
          "resolver" => Fizz.Integrations.Google.Sheets.ColumnsResolver,
          "depends_on" => @values_depends_on,
          "resource_mapper" => @row_values_mapper
        }
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "updated_range" => %{"type" => "string"},
      "updated_rows" => %{"type" => "integer"}
    }
  }

  @impl true
  def execute(config, input, ctx), do: AppendRow.execute(config, input, ctx)
end
