defmodule FizzWeb.Formatters do
  @moduledoc """
  Shared formatting helpers for LiveViews and templates.
  """

  @doc """
  Formats a timestamp for display.
  """
  def formatted_timestamp(nil), do: "-"

  def formatted_timestamp(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y at %H:%M")
  end

  @doc """
  Returns a shortened ID for display.
  """
  def short_id(nil), do: "-"

  def short_id(id) when is_binary(id) do
    String.slice(id, 0, 8)
  end

  @doc """
  Returns the CSS class for a workflow status badge.
  """
  def status_badge_class(:draft), do: "badge-warning"
  def status_badge_class(:active), do: "badge-success"
  def status_badge_class(:archived), do: "badge-neutral"
  def status_badge_class(_), do: "badge-ghost"

  @doc """
  Returns a human-readable label for a workflow status.
  """
  def status_label(:draft), do: "Draft"
  def status_label(:active), do: "Published"
  def status_label(:archived), do: "Archived"
  def status_label(status), do: to_string(status)

  @doc """
  Returns a human-readable label for the workflow trigger type.
  """
  def trigger_label(%{trigger_config: %{"type" => type}}) do
    trigger_type_label(type)
  end

  def trigger_label(%{trigger_config: %{type: type}}) do
    trigger_type_label(type)
  end

  def trigger_label(_), do: "Manual"

  @doc """
  Returns the CSS class for an execution status badge.
  """
  def execution_status_class(:completed), do: "badge-success"
  def execution_status_class(:failed), do: "badge-error"
  def execution_status_class(:running), do: "badge-info"
  def execution_status_class(:pending), do: "badge-warning"
  def execution_status_class(:paused), do: "badge-warning"
  def execution_status_class(:cancelled), do: "badge-neutral"
  def execution_status_class(:timeout), do: "badge-error"
  def execution_status_class(_), do: "badge-ghost"

  @doc """
  Formats a duration in microseconds for display.
  """
  def format_duration(nil), do: "-"
  def format_duration(us) when us < 1000, do: "#{us}μs"
  def format_duration(us) when us < 1_000_000, do: "#{Float.round(us / 1000, 2)}ms"
  def format_duration(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  @doc """
  Formats a datetime as relative time (e.g., "just now", "5m ago").
  """
  def format_relative_time(nil), do: "unknown time"

  def format_relative_time(datetime_str) when is_binary(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, dt, _} -> format_relative_time(dt)
      _ -> datetime_str
    end
  end

  def format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> formatted_timestamp(dt)
    end
  end

  defp trigger_type_label("manual"), do: "Manual"
  defp trigger_type_label(:manual), do: "Manual"
  defp trigger_type_label("schedule"), do: "Scheduled"
  defp trigger_type_label(:schedule), do: "Scheduled"
  defp trigger_type_label("event"), do: "Event"
  defp trigger_type_label(:event), do: "Event"
  defp trigger_type_label(type), do: to_string(type)
end
