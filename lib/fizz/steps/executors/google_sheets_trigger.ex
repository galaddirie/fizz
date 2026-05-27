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

  alias Fizz.Integrations.Google.Sheets.Triggers.RowChange
  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Fields
  alias Fizz.Fields.Credential
  alias Fizz.Triggers.RegistrationSpec

  @credential_field Fields.credential(GoogleOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      requirement_key: "auth"
                    )

  @default_config %{
    "credential_ref" => Fields.default_value(@credential_field),
    "event_mode" => "row_added_or_updated",
    "sheet_name" => "Sheet1",
    "range" => "A:ZZZ",
    "header_row" => 1,
    "first_data_row" => 2,
    "poll_interval_ms" => 60_000
  }

  @config_schema %{
    "type" => "object",
    "required" => ["credential_ref", "spreadsheet_id", "sheet_name"],
    "properties" => %{
      "credential_ref" => Fields.to_schema_property(@credential_field, label: "Google Account"),
      "spreadsheet_id" => %{
        "type" => "string",
        "title" => "Spreadsheet ID"
      },
      "sheet_name" => %{
        "type" => "string",
        "title" => "Sheet Name",
        "default" => "Sheet1"
      },
      "event_mode" => %{
        "type" => "string",
        "title" => "Trigger On",
        "enum" => ["row_added", "row_updated", "row_added_or_updated"],
        "default" => "row_added_or_updated"
      },
      "range" => %{
        "type" => "string",
        "title" => "Range",
        "description" => "A1 range inside the sheet, e.g. A:ZZZ",
        "default" => "A:ZZZ"
      },
      "header_row" => %{
        "type" => "integer",
        "title" => "Header Row",
        "minimum" => 1,
        "default" => 1
      },
      "first_data_row" => %{
        "type" => "integer",
        "title" => "First Data Row",
        "minimum" => 1,
        "default" => 2
      },
      "primary_key_column" => %{
        "type" => "string",
        "title" => "Primary Key Column",
        "description" => "Optional stable column name used to identify rows across inserts"
      },
      "poll_interval_ms" => %{
        "type" => "integer",
        "title" => "Poll Interval (ms)",
        "minimum" => 15000,
        "default" => 60000
      }
    }
  }

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "row_number" => %{"type" => "integer"},
      "change_type" => %{"type" => "string"},
      "values" => %{"type" => "object", "description" => "Map of column header → cell value"},
      "raw_values" => %{"type" => "array"},
      "previous_values" => %{"type" => ["object", "null"]},
      "detected_at" => %{"type" => "string", "format" => "date-time"}
    }
  }

  @impl true
  def default_config, do: @default_config

  @impl true
  def registration_spec(config, _context) do
    params =
      @default_config
      |> Map.merge(
        Map.take(config, Map.keys(@default_config) ++ ["spreadsheet_id", "primary_key_column"])
      )
      |> Map.put("provider", GoogleOAuth.provider_id())

    {:ok,
     %RegistrationSpec{
       kind: :polling,
       provider: GoogleOAuth.provider_id(),
       source_module: RowChange,
       params: params
     }}
  end

  @impl true
  def execute(_config, input, _ctx) do
    {:ok, input}
  end

  @impl true
  def normalize_event(_config, raw_event) when is_map(raw_event) do
    {:ok, raw_event}
  end

  @impl true
  def validate_config(config) do
    cond do
      not Credential.declaration?(Map.get(config, "credential_ref")) ->
        {:error, [credential_ref: "must be a credential declaration"]}

      not present?(Map.get(config, "spreadsheet_id")) ->
        {:error, [spreadsheet_id: "is required"]}

      not present?(Map.get(config, "sheet_name")) ->
        {:error, [sheet_name: "is required"]}

      event_mode(config) not in ["row_added", "row_updated", "row_added_or_updated"] ->
        {:error, [event_mode: "is invalid"]}

      poll_interval(config) < 15_000 ->
        {:error, [poll_interval_ms: "must be at least 15000"]}

      true ->
        :ok
    end
  end

  defp event_mode(config), do: Map.get(config, "event_mode", "row_added_or_updated")

  defp poll_interval(config) do
    case Map.get(config, "poll_interval_ms", 60_000) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, 60_000)
      _ -> 60_000
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
