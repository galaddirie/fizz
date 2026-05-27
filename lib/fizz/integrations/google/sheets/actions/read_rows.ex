defmodule Fizz.Integrations.Google.Sheets.Actions.ReadRows do
  @moduledoc """
  Reads rows from a Google Sheet range.
  """

  @behaviour Fizz.Integrations.Operation

  alias Fizz.Fields

  alias Fizz.Integrations.{
    OperationDefinition,
    Providers.GoogleOAuth,
    RetryPolicy
  }

  alias Fizz.Integrations.Google.Sheets.Client
  alias Fizz.Integrations.Google.Sheets.Rows

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

  @default_config Fields.defaults(@fields)
  @config_schema Fields.to_schema(@fields)

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

  @impl true
  def id, do: "google_sheets.read_rows"

  @impl true
  def definition do
    %OperationDefinition{
      id: id(),
      step_type_id: "google_sheets_read_rows",
      version: 1,
      provider: GoogleOAuth.provider_id(),
      integration: "google_sheets",
      kind: :action,
      module: __MODULE__,
      default_config: default_config(),
      fields: fields(),
      display: %{
        name: "Google Sheets — Read Rows",
        category: "Documents",
        icon: "/images/google_sheets.svg",
        description: "Read one or more rows from a Google Sheet range"
      },
      config_schema: config_schema(),
      output_schema: output_schema(),
      retry: @retry_policy
    }
  end

  @doc false
  def default_config, do: @default_config

  @doc false
  def fields, do: @fields

  @doc false
  def config_schema, do: @config_schema

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
