defmodule Fizz.Integrations.Library.Google.Sheets.Actions.ReadRows do
  @moduledoc """
  Reads rows from a Google Sheet range.
  """

  use Fizz.Integrations.Steps.Definition,
    id: "google_sheets_read_rows",
    version: 1,
    name: "Google Sheets — Read Rows",
    category: "Documents",
    description: "Read one or more rows from a Google Sheet range",
    icon: "/images/google_sheets.svg",
    kind: :action,
    provider: Fizz.Integrations.Auth.Providers.GoogleOAuth.provider_id(),
    integration: "google_sheets"

  alias Fizz.Fields

  alias Fizz.Integrations.Auth.Providers.GoogleOAuth

  alias Fizz.Integrations.Library.Google.Sheets.Client
  alias Fizz.Integrations.Library.Google.Sheets.Rows
  alias Fizz.Workflows.RetryPolicy

  @behaviour Fizz.Workflows.StepExecutor

  @fields [
    Fields.credential(GoogleOAuth.provider_id(), :oauth,
      key: "credential_ref",
      label: "Google Account",
      requirement_key: "auth",
      required?: true,
      order: 10
    ),
    Fields.string("spreadsheet_id",
      label: "Spreadsheet ID",
      required?: true,
      order: 20
    ),
    Fields.string("range",
      label: "Range",
      description: "A1 notation range, e.g. Sheet1!A1:Z100",
      default: "Sheet1!A:Z",
      order: 30
    )
  ]

  @output_schema %{
    "type" => "object",
    "properties" => %{
      "rows" => %{"type" => "array", "description" => "List of row objects with header keys"},
      "total_rows" => %{"type" => "integer"}
    }
  }
  @retry_policy %RetryPolicy{
    max_attempts: 3,
    backoff: :exponential,
    initial_delay_ms: 1_000,
    max_delay_ms: 60_000,
    retry_on: [:rate_limit, :network, :transient]
  }

  @retry @retry_policy

  @doc false
  def fields, do: @fields

  @doc false
  def output_schema, do: @output_schema

  @impl true
  def execute(config, _input, context) do
    range = Map.get(config, "range", "#{Map.get(config, "sheet_name", "Sheet1")}!A:ZZZ")

    with {:ok, values} <- Client.get_values(config, context, range) do
      rows =
        values
        |> Rows.snapshots(config, DateTime.utc_now(), %{})
        |> Enum.map(&Map.take(&1, [:row_number, :values, :raw_values]))

      {:ok, %{"rows" => rows, "total_rows" => length(rows)}}
    end
  end
end
