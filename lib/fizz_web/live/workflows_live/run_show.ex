defmodule FizzWeb.WorkflowsLive.RunShow do
  use FizzWeb, :live_view

  alias Fizz.Accounts
  alias Fizz.Workflows
  alias Fizz.Workflows.WorkflowRun

  @impl true
  def mount(params, _session, socket) do
    %{
      "project_id" => project_id,
      "definition_id" => definition_id,
      "run_id" => run_id
    } = params

    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:definition_id, definition_id)
      |> assign(:run_id, run_id)
      |> assign(:definition, nil)
      |> assign(:run, nil)
      |> assign(:step_executions, [])
      |> assign(:expanded_steps, MapSet.new())
      |> assign(:step_io, %{})
      |> assign(:page_title, "Run")

    {:ok, load_run(socket)}
  end

  @impl true
  def handle_event("toggle_step", %{"step_id" => step_execution_id}, socket) do
    expanded = socket.assigns.expanded_steps

    socket =
      if MapSet.member?(expanded, step_execution_id) do
        assign(socket, :expanded_steps, MapSet.delete(expanded, step_execution_id))
      else
        socket
        |> assign(:expanded_steps, MapSet.put(expanded, step_execution_id))
        |> maybe_load_step_io(step_execution_id)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("expand_all", _params, socket) do
    all_ids =
      socket.assigns.step_executions
      |> Enum.map(& &1.id)
      |> MapSet.new()

    socket =
      socket
      |> assign(:expanded_steps, all_ids)
      |> load_all_step_io()

    {:noreply, socket}
  end

  @impl true
  def handle_event("collapse_all", _params, socket) do
    {:noreply, assign(socket, :expanded_steps, MapSet.new())}
  end

  defp load_run(socket) do
    %{project_id: project_id, definition_id: definition_id, run_id: run_id} = socket.assigns

    with {:ok, scope} <-
           Accounts.build_scope_for_project(socket.assigns.current_scope, project_id),
         {:ok, definition} <- Workflows.get_definition(scope, definition_id),
         {:ok, run} <- Workflows.get_run(scope, run_id),
         {:ok, step_executions} <- Workflows.list_run_step_executions(scope, run_id) do
      step_name_map = build_step_name_map(definition)

      step_executions =
        Enum.map(step_executions, fn se ->
          Map.put(se, :step_name, Map.get(step_name_map, se.step_id, se.step_id))
        end)

      socket
      |> assign(:resolve_project_scope, scope)
      |> assign(:definition, definition)
      |> assign(:run, run)
      |> assign(:step_executions, step_executions)
      |> assign(:page_title, "Run #{short_id(run.id)}")
    else
      {:error, :project_not_found} ->
        socket
        |> put_flash(:error, "Project not found")
        |> redirect(to: ~p"/projects")

      {:error, :definition_not_found} ->
        socket
        |> put_flash(:error, "Workflow not found")
        |> redirect(to: ~p"/projects/#{project_id}")

      {:error, :run_not_found} ->
        socket
        |> put_flash(:error, "Run not found")
        |> redirect(to: ~p"/projects/#{project_id}/workflows/#{definition_id}")

      {:error, _reason} ->
        socket
        |> put_flash(:error, "Could not load run")
        |> redirect(to: ~p"/projects/#{project_id}/workflows/#{definition_id}")
    end
  end

  defp build_step_name_map(definition) do
    definition.versions
    |> Enum.flat_map(& &1.steps)
    |> Map.new(fn step -> {step.id, step.name} end)
  end

  defp maybe_load_step_io(socket, step_execution_id) do
    if Map.has_key?(socket.assigns.step_io, step_execution_id) do
      socket
    else
      load_step_io(socket, step_execution_id)
    end
  end

  defp load_step_io(socket, step_execution_id) do
    scope = socket.assigns.resolve_project_scope
    run_id = socket.assigns.run_id

    case Workflows.load_run_step_io(scope, run_id, step_execution_id) do
      {:ok, io_data} ->
        step_io = Map.put(socket.assigns.step_io, step_execution_id, io_data)
        assign(socket, :step_io, step_io)

      {:error, _reason} ->
        socket
    end
  end

  defp load_all_step_io(socket) do
    Enum.reduce(socket.assigns.step_executions, socket, fn se, acc ->
      maybe_load_step_io(acc, se.id)
    end)
  end

  defp run_status_badge(:completed), do: {"Completed", "badge-success"}
  defp run_status_badge(:failed), do: {"Failed", "badge-error"}
  defp run_status_badge(:running), do: {"Running", "badge-info"}
  defp run_status_badge(:pending), do: {"Pending", "badge-warning"}
  defp run_status_badge(:sleeping), do: {"Sleeping", "badge-warning"}
  defp run_status_badge(:passivated), do: {"Paused", "badge-warning"}
  defp run_status_badge(:cancelled), do: {"Cancelled", "badge-ghost"}
  defp run_status_badge(:continued), do: {"Continued", "badge-ghost"}
  defp run_status_badge(_), do: {"Unknown", "badge-ghost"}

  defp step_status_dot("completed"), do: "bg-success"
  defp step_status_dot("failed"), do: "bg-error"
  defp step_status_dot("running"), do: "bg-info animate-pulse"
  defp step_status_dot(_), do: "bg-base-content/30"

  defp step_status_label("completed"), do: "Completed"
  defp step_status_label("failed"), do: "Failed"
  defp step_status_label("running"), do: "Running"
  defp step_status_label(_), do: "Unknown"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: ""

  defp formatted_timestamp(nil), do: "—"

  defp formatted_timestamp(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, parsed, _} -> Calendar.strftime(parsed, "%b %d, %Y at %H:%M:%S")
      _ -> dt
    end
  end

  defp formatted_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y at %H:%M:%S")
  end

  defp formatted_timestamp(_), do: "—"

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

  defp format_step_duration(nil), do: "—"

  defp format_step_duration(duration_us) when is_integer(duration_us) do
    cond do
      duration_us < 1_000 -> "<1ms"
      duration_us < 1_000_000 -> "#{div(duration_us, 1_000)}ms"
      true -> "#{Float.round(duration_us / 1_000_000, 1)}s"
    end
  end

  defp format_step_duration(_), do: "—"

  defp format_data(nil), do: "null"

  defp format_data(data) when is_map(data) or is_list(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(data, pretty: true)
    end
  end

  defp format_data(data), do: inspect(data, pretty: true)

  defp step_type_label(type_id) do
    type_id
    |> String.split("/")
    |> List.last()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp debug_json(run, step_executions) do
    %{
      run: sanitize_for_json(run),
      step_executions: Enum.map(step_executions, &sanitize_for_json/1)
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
  defp sanitize_for_json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> sanitize_for_json()
  defp sanitize_for_json(pid) when is_pid(pid), do: inspect(pid)
  defp sanitize_for_json(ref) when is_reference(ref), do: inspect(ref)
  defp sanitize_for_json(fun) when is_function(fun), do: inspect(fun)
  defp sanitize_for_json(value), do: value
end
