defmodule Fizz.Integrations.Library.Google.Sheets.RowsTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.Library.Google.Sheets.Rows

  test "snapshots normalize rows with header values and primary key identity" do
    now = DateTime.utc_now()

    snapshots =
      Rows.snapshots(
        [
          ["id", "name"],
          ["1", "Ada"],
          ["2", "Grace"]
        ],
        %{"primary_key_column" => "id"},
        now
      )

    assert [
             %{
               row_key: "pk:1",
               row_number: 2,
               values: %{"id" => "1", "name" => "Ada"},
               raw_values: ["1", "Ada"]
             },
             %{
               row_key: "pk:2",
               row_number: 3,
               values: %{"id" => "2", "name" => "Grace"},
               raw_values: ["2", "Grace"]
             }
           ] = snapshots
  end

  test "change_events emits added and updated rows for row_added_or_updated mode" do
    now = DateTime.utc_now()

    [existing_snapshot] =
      Rows.snapshots(
        [
          ["id", "name"],
          ["1", "Ada"]
        ],
        %{"primary_key_column" => "id"},
        now
      )

    snapshots =
      Rows.snapshots(
        [
          ["id", "name"],
          ["1", "Ada Lovelace"],
          ["2", "Grace Hopper"]
        ],
        %{"primary_key_column" => "id"},
        now,
        %{existing_snapshot.row_key => existing_snapshot}
      )

    events =
      Rows.change_events(
        snapshots,
        %{existing_snapshot.row_key => existing_snapshot},
        "row_added_or_updated",
        %{"spreadsheet_id" => "spreadsheet_1", "sheet_name" => "Sheet1", "range" => "A:B"}
      )

    assert Enum.map(events, & &1["change_type"]) == ["updated", "added"]
    assert Enum.map(events, & &1["row_key"]) == ["pk:1", "pk:2"]
    assert hd(events)["previous_values"] == %{"id" => "1", "name" => "Ada"}
  end

  test "change_events suppresses added rows in row_updated mode" do
    now = DateTime.utc_now()

    snapshots =
      Rows.snapshots(
        [
          ["id", "name"],
          ["1", "Ada"]
        ],
        %{"primary_key_column" => "id"},
        now
      )

    assert [] =
             Rows.change_events(
               snapshots,
               %{},
               "row_updated",
               %{"spreadsheet_id" => "spreadsheet_1", "sheet_name" => "Sheet1"}
             )
  end
end
