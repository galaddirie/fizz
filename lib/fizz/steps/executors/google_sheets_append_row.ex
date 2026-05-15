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

  @config_schema %{
    "type" => "object",
    "required" => ["credential_ref", "spreadsheet_id", "values"],
    "properties" => %{
      "credential_ref" => CredentialSlot.schema(@credential_slot, title: "Google Account"),
      "spreadsheet_id" => %{
        "type" => "string",
        "title" => "Spreadsheet ID"
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
        "ui" => %{
          "component" => "map",
          "resolver" => Fizz.Integrations.Google.Sheets.ColumnsResolver
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
