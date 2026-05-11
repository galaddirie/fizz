defmodule Fizz.Steps.Executors.GoogleSheetsTrigger do
  @moduledoc """
  Trigger that fires when a new row is added to a Google Sheet.
  """

  use Fizz.Steps.Definition,
    id: "google_sheets_trigger",
    name: "Google Sheets — New Row",
    category: "Triggers",
    description: "Fires when a new row is appended to a Google Sheet",
    icon: "/images/google_sheets.svg",
    kind: :trigger

  @behaviour Fizz.Steps.Executors.Behaviour

  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Slots.CredentialSlot

  @credential_slot CredentialSlot.oauth(GoogleOAuth.provider_id())

  @default_config %{
    "credential_ref" => CredentialSlot.declaration(@credential_slot)
  }

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "credential_ref" => CredentialSlot.schema(@credential_slot, title: "Google Account"),
      "spreadsheet_id" => %{
        "type" => "string",
        "title" => "Spreadsheet ID"
      },
      "sheet_name" => %{
        "type" => "string",
        "title" => "Sheet Name",
        "default" => "Sheet1"
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "row_number" => %{"type" => "integer"},
      "values" => %{"type" => "object", "description" => "Map of column header → cell value"},
      "raw_values" => %{"type" => "array"}
    }
  }

  @impl true
  def execute(_config, _input, _ctx) do
    # TODO: Implement Google Sheets polling / push trigger
    {:ok, %{}}
  end
end
