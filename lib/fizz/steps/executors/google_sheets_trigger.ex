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

  @behaviour Fizz.Steps.Executor

  alias Fizz.Integrations.Google.Sheets.Triggers.RowChange
  alias Fizz.Integrations.Providers.GoogleOAuth
  alias Fizz.Fields
  alias Fizz.Fields.Credential
  alias Fizz.Triggers.RegistrationSpec

  @credential_field Fields.credential(GoogleOAuth.provider_id(), :oauth,
                      key: "credential_ref",
                      label: "Google Account",
                      requirement_key: "auth"
                    )

  @fields [
    @credential_field,
    Fields.string("spreadsheet_id", label: "Spreadsheet ID", required?: true),
    Fields.string("sheet_name", label: "Sheet Name", required?: true, default: "Sheet1"),
    Fields.select("event_mode",
      label: "Trigger On",
      default: "row_added_or_updated",
      options: Fields.options(~w(row_added row_updated row_added_or_updated))
    ),
    Fields.string("range",
      label: "Range",
      description: "A1 range inside the sheet, e.g. A:ZZZ",
      default: "A:ZZZ"
    ),
    Fields.number("header_row", label: "Header Row", minimum: 1, default: 1),
    Fields.number("first_data_row", label: "First Data Row", minimum: 1, default: 2),
    Fields.string("primary_key_column",
      label: "Primary Key Column",
      description: "Optional stable column name used to identify rows across inserts"
    ),
    Fields.number("poll_interval_ms",
      label: "Poll Interval (ms)",
      minimum: 15_000,
      default: 60_000
    )
  ]

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
  def registration_spec(config, _context) do
    default_config = default_config()

    params =
      default_config
      |> Map.merge(
        Map.take(config, Map.keys(default_config) ++ ["spreadsheet_id", "primary_key_column"])
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
