defmodule FizzWeb.WorkflowLive.Revision do
  use FizzWeb, :live_view

  alias Ecto.UUID
  alias Fizz.Collaboration.EditSession.{Server, Supervisor}
  alias Fizz.Workflows
  alias Fizz.Steps
  require Logger

  @impl true
  def mount(%{"id" => workflow_id}, _session, socket) do
    scope = socket.assigns.current_scope
    user = scope.user

    with {:ok, workflow} <- Workflows.get_workflow_with_draft(scope, workflow_id),
         {:ok, _pid} <- Supervisor.ensure_session(workflow.id) do
      socket =
        socket
        |> assign(:page_title, "Revisions · #{workflow.name}")
        |> assign(:workflow, workflow)
        |> assign(:draft, workflow.draft)
        |> assign(:step_types, Steps.list_types())
        |> assign(
          :versions,
          serialize_versions(Workflows.list_workflow_versions(scope, workflow))
        )
        |> assign(:undo_stack, fetch_undo_stack(workflow.id, user.id))
        |> assign(:revision, %{kind: "current", label: "Current Draft"})
        |> assign(:editor_state, fetch_editor_state(workflow.id))
        |> assign(:current_user_id, user.id)

      {:ok, socket, layout: false}
    else
      {:error, :not_found} ->
        {:ok, socket |> put_flash(:error, "Workflow not found") |> redirect(to: ~p"/workflows")}

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, "You do not have permission to view this workflow")
         |> redirect(to: ~p"/workflows")}

      {:error, reason} ->
        Logger.warning("Revision viewer mount failed: #{inspect(reason)}")

        {:ok,
         socket
         |> put_flash(:error, "Unable to load revisions")
         |> redirect(to: ~p"/workflows")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_revision(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} hide_nav={true} full_bleed={true}>
      <div class="h-screen w-full overflow-hidden bg-base-200">
        <.vue
          v-component="RevisionViewer"
          v-ssr={false}
          v-socket={@socket}
          workflow={@workflow}
          draft={@draft}
          revision={@revision}
          versions={@versions}
          undoStack={@undo_stack}
          stepTypes={@step_types}
          editorState={@editor_state}
          v-on:select_revision={JS.push("select_revision")}
          v-on:apply_revision={JS.push("apply_revision")}
          v-on:navigate_back={JS.push("navigate_back")}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("select_revision", %{"kind" => "current"}, socket) do
    {:noreply, push_patch(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}/revisions")}
  end

  def handle_event("select_revision", %{"kind" => "undo", "depth" => depth}, socket) do
    depth = parse_count(depth)

    {:noreply,
     push_patch(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}/revisions?undo=#{depth}")}
  end

  def handle_event("select_revision", %{"kind" => "version", "id" => version_id}, socket) do
    {:noreply,
     push_patch(
       socket,
       to: ~p"/workflows/#{socket.assigns.workflow.id}/revisions?version=#{version_id}"
     )}
  end

  @impl true
  def handle_event("apply_revision", _params, socket) do
    case apply_current_revision(socket) do
      {:ok, _} ->
        {:noreply, push_navigate(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}/edit")}

      {:error, reason} ->
        Logger.warning("Revision apply failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Unable to apply revision")}
    end
  end

  def handle_event("navigate_back", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}/edit")}
  end

  defp load_revision(socket, %{"undo" => depth}) do
    depth = parse_count(depth)
    workflow_id = socket.assigns.workflow.id
    user_id = socket.assigns.current_user_id

    case Server.preview_undo(workflow_id, user_id, depth) do
      {:ok, draft} ->
        label =
          socket.assigns.undo_stack
          |> Enum.find_value(fn entry ->
            if entry.depth == depth, do: entry.label
          end)
          |> case do
            nil -> "Undo #{depth}"
            value -> value
          end

        socket
        |> assign(:draft, draft)
        |> assign(:revision, %{kind: "undo", depth: depth, label: label})

      {:error, reason} ->
        Logger.warning("Revision preview failed: #{inspect(reason)}")

        socket
        |> put_flash(:error, "Could not load undo preview")
        |> assign(:draft, socket.assigns.workflow.draft)
        |> assign(:revision, %{kind: "current", label: "Current Draft"})
    end
  end

  defp load_revision(socket, %{"version" => version_id}) do
    case Workflows.get_workflow_version(socket.assigns.current_scope, version_id) do
      {:ok, version} ->
        draft = build_version_draft(socket.assigns.workflow, version)

        socket
        |> assign(:draft, draft)
        |> assign(:revision, %{kind: "version", id: version_id, label: "v#{version.version_tag}"})

      {:error, reason} ->
        Logger.warning("Version lookup failed: #{inspect(reason)}")

        socket
        |> put_flash(:error, "Version not found")
        |> assign(:draft, socket.assigns.workflow.draft)
        |> assign(:revision, %{kind: "current", label: "Current Draft"})
    end
  end

  defp load_revision(socket, _params) do
    socket
    |> assign(:draft, socket.assigns.workflow.draft)
    |> assign(:revision, %{kind: "current", label: "Current Draft"})
  end

  defp build_version_draft(workflow, version) do
    case workflow.draft do
      %{} = draft ->
        %{
          draft
          | steps: List.wrap(version.steps || []),
            connections: List.wrap(version.connections || []),
            groups: List.wrap(version.groups || [])
        }

      _ ->
        %{
          workflow_id: workflow.id,
          steps: List.wrap(version.steps || []),
          connections: List.wrap(version.connections || []),
          groups: List.wrap(version.groups || []),
          settings: %{}
        }
    end
  end

  defp apply_current_revision(socket) do
    case socket.assigns.revision do
      %{kind: "undo", depth: depth} ->
        Server.undo(socket.assigns.workflow.id, socket.assigns.current_user_id, depth)

      %{kind: "version", id: version_id} ->
        apply_version_restoration(socket, version_id)

      _ ->
        {:ok, :no_change}
    end
  end

  defp apply_version_restoration(socket, version_id) do
    with %{} = draft <- socket.assigns.workflow.draft,
         {:ok, version} <-
           Workflows.get_workflow_version(socket.assigns.current_scope, version_id) do
      label = "Restore v#{version.version_tag}"
      operations = build_revision_operations(draft, version, label)

      case apply_operations(socket, operations) do
        :ok -> {:ok, :applied}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_version}
    end
  end

  defp fetch_undo_stack(workflow_id, user_id) do
    case Server.get_undo_state(workflow_id, user_id) do
      {:ok, state} -> Map.get(state, :undoStack, [])
      _ -> []
    end
  end

  defp fetch_editor_state(workflow_id) do
    case Server.get_editor_state(workflow_id) do
      {:ok, editor_state} -> editor_state
      _ -> nil
    end
  end

  defp serialize_versions(versions) do
    Enum.map(versions, fn version ->
      %{
        id: version.id,
        version_tag: version.version_tag,
        published_at: format_timestamp(version.published_at)
      }
    end)
  end

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(_timestamp), do: nil

  defp apply_operations(_socket, []), do: :ok

  defp apply_operations(socket, operations) do
    Enum.reduce_while(operations, :ok, fn
      {type, payload}, :ok ->
        operation = build_operation(socket, type, payload, %{})

        case Server.apply_operation(socket.assigns.workflow.id, operation) do
          {:ok, _result} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {type, payload, opts}, :ok ->
        operation = build_operation(socket, type, payload, opts)

        case Server.apply_operation(socket.assigns.workflow.id, operation) do
          {:ok, _result} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp build_operation(socket, type, payload, opts) do
    %{
      id: UUID.generate(),
      type: type,
      payload: payload,
      user_id: socket.assigns.current_user_id,
      client_seq: nil,
      undo_group_id: Map.get(opts, :undo_group_id),
      undo_label: Map.get(opts, :undo_label)
    }
  end

  defp build_revision_operations(draft, version, label) do
    undo_group_id = UUID.generate()
    opts = %{undo_group_id: undo_group_id, undo_label: label}

    remove_group_ops =
      draft.groups
      |> List.wrap()
      |> Enum.map(fn group ->
        {:remove_group, %{group_id: fetch_field(group, :id)}, opts}
      end)

    remove_step_ops =
      draft.steps
      |> List.wrap()
      |> Enum.map(fn step ->
        {:remove_step, %{step_id: fetch_field(step, :id)}, opts}
      end)

    target_steps = List.wrap(fetch_field(version, :steps) || [])
    target_groups = List.wrap(fetch_field(version, :groups) || [])
    target_connections = List.wrap(fetch_field(version, :connections) || [])

    add_step_ops =
      Enum.map(target_steps, fn step ->
        {:add_step, %{step: normalize_step(step)}, opts}
      end)

    add_group_ops =
      Enum.map(target_groups, fn group ->
        group_map = normalize_group(group)
        step_positions = build_group_step_positions(target_steps, group_map)
        {:add_group, %{group: group_map, step_positions: step_positions}, opts}
      end)

    add_connection_ops =
      Enum.map(target_connections, fn connection ->
        {:add_connection, %{connection: normalize_connection(connection)}, opts}
      end)

    remove_group_ops ++ remove_step_ops ++ add_step_ops ++ add_group_ops ++ add_connection_ops
  end

  defp normalize_step(step) do
    %{
      id: fetch_field(step, :id),
      type_id: fetch_field(step, :type_id),
      name: fetch_field(step, :name),
      config: fetch_field(step, :config) || %{},
      position: normalize_position(fetch_field(step, :position) || %{}),
      notes: fetch_field(step, :notes)
    }
  end

  defp normalize_connection(connection) do
    %{
      id: fetch_field(connection, :id),
      source_step_id: fetch_field(connection, :source_step_id),
      source_output: fetch_field(connection, :source_output) || "main",
      target_step_id: fetch_field(connection, :target_step_id),
      target_input: fetch_field(connection, :target_input) || "main"
    }
  end

  defp normalize_group(group) do
    %{
      id: fetch_field(group, :id),
      name: fetch_field(group, :name) || "Group",
      step_ids: List.wrap(fetch_field(group, :step_ids) || []),
      output_step_id: fetch_field(group, :output_step_id),
      position: normalize_group_position(fetch_field(group, :position) || %{}),
      color: fetch_field(group, :color),
      collapsed: fetch_field(group, :collapsed) || false
    }
  end

  defp build_group_step_positions(steps, group) do
    step_ids = Map.get(group, :step_ids) || []

    Enum.reduce(steps, %{}, fn step, acc ->
      step_id = fetch_field(step, :id)

      if step_id in step_ids do
        position = normalize_position(fetch_field(step, :position) || %{})
        Map.put(acc, step_id, position)
      else
        acc
      end
    end)
  end

  defp normalize_position(position) when is_map(position) do
    %{
      x: fetch_field(position, :x) || 0,
      y: fetch_field(position, :y) || 0
    }
  end

  defp normalize_position(_position), do: %{x: 0, y: 0}

  defp normalize_group_position(position) when is_map(position) do
    %{
      x: fetch_field(position, :x) || 0,
      y: fetch_field(position, :y) || 0,
      width: fetch_field(position, :width),
      height: fetch_field(position, :height)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_group_position(_position), do: %{}

  defp fetch_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp fetch_field(_map, _key), do: nil

  defp parse_count(count) when is_integer(count) and count > 0, do: count

  defp parse_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {value, _} when value > 0 -> value
      _ -> 1
    end
  end

  defp parse_count(_count), do: 1
end
