defmodule Fizz.Steps.Executors.GoogleSheetsReadRows do
  @moduledoc """
  Reads rows from a Google Sheet range.
  """

  use Fizz.Steps.Definition,
    id: "google_sheets_read_rows",
    name: "Google Sheets — Read Rows",
    category: "Documents",
    description: "Read one or more rows from a Google Sheet range",
    icon: "/images/google_sheets.svg",
    kind: :action

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Google.Sheets.Actions.ReadRows
  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Slots.CredentialSlot

  @credential_slot CredentialSlot.oauth(GoogleOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialSlot.declaration(@credential_slot)
  }

  @config_schema %{
    "type" => "object",
    "required" => ["spreadsheet_id"],
    "properties" => %{
      "credential_ref" => CredentialSlot.schema(@credential_slot, title: "Google Account"),
      "spreadsheet_id" => %{
        "type" => "string",
        "title" => "Spreadsheet ID"
      },
      "range" => %{
        "type" => "string",
        "title" => "Range",
        "description" => "A1 notation range, e.g. Sheet1!A1:Z100",
        "default" => "Sheet1!A:Z"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "rows" => %{"type" => "array", "description" => "List of row objects with header keys"},
      "total_rows" => %{"type" => "integer"}
    }
  }

  @impl true
  def execute(config, input, ctx), do: ReadRows.execute(config, input, ctx)
end
