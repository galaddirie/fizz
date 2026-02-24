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

  @config_schema %{
    "type" => "object",
    "required" => ["spreadsheet_id", "values"],
    "properties" => %{
      "credential_ref" => %{
        "type" => "object",
        "title" => "Google Account"
      },
      "spreadsheet_id" => %{
        "type" => "string",
        "title" => "Spreadsheet ID"
      },
      "sheet_name" => %{
        "type" => "string",
        "title" => "Sheet Name",
        "default" => "Sheet1"
      },
      "values" => %{
        "type" => "object",
        "title" => "Row Values",
        "description" => "Map of column header → value"
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
  def execute(_config, _input, _ctx) do
    # TODO: Implement Google Sheets values.append
    {:ok, %{}}
  end
end
