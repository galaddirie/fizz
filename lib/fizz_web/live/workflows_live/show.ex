defmodule FizzWeb.WorkflowsLive.Show do
  use FizzWeb, :live_view

  alias Fizz.Accounts
  alias Fizz.Workflows
  alias Fizz.Workflows.WorkflowRun

  @impl true
  def mount(%{"project_id" => project_id, "definition_id" => definition_id}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:definition_id, definition_id)
      |> assign(:definition, nil)
      |> assign(:latest_version, nil)
      |> assign(:page_title, "Workflow")
      |> assign(:runs_empty?, true)
      |> assign(:run_counts, %{})
      |> assign(:step_summary, [])
      |> stream(:runs, [])

    {:ok, load_workflow(socket)}
  end

  defp load_workflow(socket) do
    %{project_id: project_id, definition_id: definition_id} = socket.assigns

    with {:ok, scope} <-
           Accounts.build_scope_for_project(socket.assigns.current_scope, project_id),
         {:ok, definition} <- Workflows.get_definition(scope, definition_id) do
      latest_version = latest_version(definition)
      step_summary = build_step_summary(latest_version)

      socket =
        socket
        |> assign(:resolve_project_scope, scope)
        |> assign(:definition, definition)
        |> assign(:latest_version, latest_version)
        |> assign(:page_title, definition.name || "Workflow")
        |> assign(:step_summary, step_summary)

      load_runs(socket, scope, definition_id)
    else
      {:error, :project_not_found} ->
        socket
        |> put_flash(:error, "Project not found")
        |> redirect(to: ~p"/projects")

      {:error, :definition_not_found} ->
        socket
        |> put_flash(:error, "Workflow not found")
        |> redirect(to: ~p"/projects/#{project_id}")

      {:error, :forbidden} ->
        socket
        |> put_flash(:error, "You do not have access to this project")
        |> redirect(to: ~p"/projects")

      {:error, _reason} ->
        socket
        |> put_flash(:error, "Could not load workflow")
        |> redirect(to: ~p"/projects/#{project_id}/workflows")
    end
  end

  defp load_runs(socket, scope, definition_id) do
    case Workflows.list_runs(scope, definition_id: definition_id) do
      {:ok, runs} ->
        socket
        |> assign(:runs_empty?, runs == [])
        |> assign(:run_counts, build_run_counts(runs))
        |> stream(:runs, runs, reset: true)

      {:error, _reason} ->
        socket
    end
  end

  defp latest_version(%{versions: [latest | _]}), do: latest
  defp latest_version(_), do: nil

  defp build_step_summary(nil), do: []

  defp build_step_summary(version) do
    version.steps
    |> Enum.frequencies_by(& &1.type_id)
    |> Enum.sort_by(fn {_type, count} -> count end, :desc)
  end

  defp build_run_counts(runs) do
    counts = Enum.frequencies_by(runs, & &1.status)

    %{
      total: length(runs),
      completed: Map.get(counts, :completed, 0),
      failed: Map.get(counts, :failed, 0),
      running: Map.get(counts, :running, 0) + Map.get(counts, :pending, 0),
      cancelled: Map.get(counts, :cancelled, 0)
    }
  end

  defp version_status_badge(:published), do: {"Published", "badge-success"}
  defp version_status_badge(:draft), do: {"Draft", "badge-warning"}
  defp version_status_badge(:archived), do: {"Archived", "badge-ghost"}
  defp version_status_badge(_), do: {"Unknown", "badge-ghost"}

  defp run_status_badge(:completed), do: {"Completed", "badge-success"}
  defp run_status_badge(:failed), do: {"Failed", "badge-error"}
  defp run_status_badge(:running), do: {"Running", "badge-info"}
  defp run_status_badge(:pending), do: {"Pending", "badge-warning"}
  defp run_status_badge(:sleeping), do: {"Sleeping", "badge-warning"}
  defp run_status_badge(:passivated), do: {"Paused", "badge-warning"}
  defp run_status_badge(:cancelled), do: {"Cancelled", "badge-ghost"}
  defp run_status_badge(:continued), do: {"Continued", "badge-ghost"}
  defp run_status_badge(_), do: {"Unknown", "badge-ghost"}

  defp run_status_dot(:completed), do: "bg-success"
  defp run_status_dot(:failed), do: "bg-error"
  defp run_status_dot(:running), do: "bg-info animate-pulse"
  defp run_status_dot(:pending), do: "bg-warning animate-pulse"
  defp run_status_dot(:sleeping), do: "bg-warning"
  defp run_status_dot(:passivated), do: "bg-warning"
  defp run_status_dot(:cancelled), do: "bg-base-content/30"
  defp run_status_dot(:continued), do: "bg-base-content/30"
  defp run_status_dot(_), do: "bg-base-content/30"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: ""

  defp formatted_timestamp(nil), do: "—"

  defp formatted_timestamp(dt) do
    Calendar.strftime(dt, "%b %d, %Y at %H:%M")
  end

  defp formatted_date(nil), do: "—"

  defp formatted_date(dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end

  defp run_duration(%WorkflowRun{started_at: nil}), do: "—"

  defp run_duration(%WorkflowRun{completed_at: nil, started_at: started_at}) do
    seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)
    format_duration(seconds)
  end

  defp run_duration(%WorkflowRun{started_at: started_at, completed_at: completed_at}) do
    seconds = DateTime.diff(completed_at, started_at, :second)
    format_duration(seconds)
  end

  defp format_duration(seconds) when seconds < 1, do: "<1s"
  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}m #{secs}s"
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  defp step_type_label(type_id) do
    type_id
    |> String.split("/")
    |> List.last()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp debug_json(definition, latest_version) do
    %{
      definition: sanitize_for_json(definition),
      latest_version: sanitize_for_json(latest_version)
    }
    |> Jason.encode!(pretty: true)
  end

  defp sanitize_for_json(%Ecto.Association.NotLoaded{}), do: nil

  defp sanitize_for_json(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {k, v} -> {k, sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(%{} = map), do: Map.new(map, fn {k, v} -> {k, sanitize_for_json(v)} end)
  defp sanitize_for_json(list) when is_list(list), do: Enum.map(list, &sanitize_for_json/1)

  defp sanitize_for_json(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> sanitize_for_json()

  defp sanitize_for_json(pid) when is_pid(pid), do: inspect(pid)
  defp sanitize_for_json(ref) when is_reference(ref), do: inspect(ref)
  defp sanitize_for_json(fun) when is_function(fun), do: inspect(fun)
  defp sanitize_for_json(value), do: value
end
