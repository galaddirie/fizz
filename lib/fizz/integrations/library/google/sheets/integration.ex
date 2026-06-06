defmodule Fizz.Integrations.Library.Google.Sheets do
  @moduledoc """
  Google Sheets integration definition.
  """

  @behaviour Fizz.Integrations.Contracts.Integration

  alias Fizz.Integrations.Auth.Providers.GoogleOAuth

  @impl true
  def id, do: "google_sheets"

  @impl true
  def display_name, do: "Google Sheets"

  @impl true
  def provider_id, do: GoogleOAuth.provider_id()

  @impl true
  def actions do
    [
      "google_sheets_read_rows",
      "google_sheets_append_row"
    ]
  end

  @impl true
  def triggers do
    [
      Fizz.Integrations.Library.Google.Sheets.Triggers.RowChange
    ]
  end

  @impl true
  def step_modules do
    [
      Fizz.Integrations.Library.Google.Sheets.Triggers.NewRow,
      Fizz.Integrations.Library.Google.Sheets.Actions.ReadRows,
      Fizz.Integrations.Library.Google.Sheets.Actions.AppendRow
    ]
  end

  @impl true
  def required_scopes(:read_rows), do: ["https://www.googleapis.com/auth/spreadsheets.readonly"]
  def required_scopes(:append_row), do: ["https://www.googleapis.com/auth/spreadsheets"]

  def required_scopes(:row_change) do
    [
      "https://www.googleapis.com/auth/spreadsheets.readonly"
    ]
  end

  def required_scopes(_operation), do: []
end
