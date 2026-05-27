defmodule FizzWeb.WorkflowsLive.Revisions do
  use FizzWeb, :live_view
  use LiveVue, :live_view

  alias Fizz.Accounts
  alias Fizz.Integrations.StepRegistry
  alias Fizz.Workflows
  alias Fizz.Workflows.DraftSession
  alias Fizz.Workflows.WorkflowDefinitionVersion
  alias FizzWeb.WorkflowsLive.Payload

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign_defaults(params)
      |> load_revision_base(params)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_selected_revision(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} hide_nav={true} full_bleed={true}>
      <%= if @workflow && @selected_draft_payload do %>
        <.vue
          id="workflow-revision-viewer"
          v-component="RevisionViewer"
          v-socket={@socket}
          workflow={@workflow}
          draft={@selected_draft_payload}
          revision={@selected_revision}
          versions={@versions}
          undoStack={@undo_stack}
          stepTypes={@step_types}
          editorState={@editor_state}
        />
      <% else %>
        <div id="workflow-revision-viewer-loading" />
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("select_revision", payload, socket) do
    {:noreply, push_patch(socket, to: revision_workflow_path(socket, payload))}
  end

  def handle_event(
        "apply_revision",
        _params,
        %{assigns: %{selected_revision: %{"kind" => "current"}}} = socket
      ) do
    {:noreply, push_navigate(socket, to: edit_workflow_path(socket))}
  end

  def handle_event("apply_revision", _params, socket) do
    case apply_selected_revision(socket) do
      {:ok, next_socket} ->
        {:noreply, push_navigate(next_socket, to: edit_workflow_path(socket))}

      {:error, next_socket} ->
        {:noreply, next_socket}
    end
  end

  @impl true
  def handle_event("navigate_back", _params, socket) do
    {:noreply, push_navigate(socket, to: edit_workflow_path(socket))}
  end

  @impl true
  def terminate(_reason, socket) do
    maybe_leave_draft_session(socket)
    :ok
  end

  defp assign_defaults(socket, params) do
    socket
    |> assign(:project_id, Map.get(params, "project_id"))
    |> assign(:definition_id, Map.get(params, "definition_id"))
    |> assign(:page_title, "Workflow Revisions")
    |> assign(:workflow, nil)
    |> assign(:definition, nil)
    |> assign(:current_draft, nil)
    |> assign(:selected_draft, nil)
    |> assign(:selected_draft_payload, nil)
    |> assign(:selected_revision, %{"kind" => "current", "label" => "Current draft"})
    |> assign(:undo_stack, [])
    |> assign(:versions, [])
    |> assign(:step_types, [])
    |> assign(:editor_state, initial_editor_state(nil))
    |> assign(:project_name, nil)
    |> assign(:current_user_id, current_user_id(socket))
    |> assign(:draft_session_joined?, false)
  end

  defp load_revision_base(
         socket,
         %{"project_id" => project_id, "definition_id" => definition_id}
       ) do
    with {:ok, scope} <-
           Accounts.build_scope_for_project(socket.assigns.current_scope, project_id),
         {:ok, definition} <- Workflows.get_definition(scope, definition_id),
         {:ok, draft} <- Workflows.edit_definition(scope, definition_id),
         {:ok, joined_draft, undo_state, editor_state, joined?} <-
           maybe_connect_draft_session(socket, scope, draft) do
      step_types = StepRegistry.all()

      socket
      |> assign(:current_scope, scope)
      |> assign(:project_name, scope.project.name)
      |> assign(:page_title, "#{definition.name} Revisions")
      |> assign(:definition, definition)
      |> assign(:current_draft, joined_draft)
      |> assign(:workflow, Payload.workflow(definition, joined_draft, scope.project.name))
      |> assign(:versions, Payload.published_versions(definition))
      |> assign(:undo_stack, Map.get(undo_state, :undoStack, []))
      |> assign(:step_types, Enum.map(step_types, &Payload.step_type/1))
      |> assign(:editor_state, Map.put(editor_state, :workflow_id, definition.id))
      |> assign(:draft_session_joined?, joined?)
    else
      {:error, :project_not_found} ->
        redirect_with_error(socket, "Project not found", ~p"/projects")

      {:error, :definition_not_found} ->
        redirect_with_error(socket, "Workflow not found", ~p"/projects/#{project_id}")

      {:error, :forbidden} ->
        redirect_with_error(
          socket,
          "You do not have access to this project",
          ~p"/projects"
        )

      {:error, reason} ->
        redirect_with_error(
          socket,
          "Could not load workflow revisions: #{inspect(reason)}",
          ~p"/projects"
        )
    end
  end

  defp load_revision_base(socket, _params),
    do: redirect_with_error(socket, "Workflow not found", ~p"/projects")

  defp maybe_connect_draft_session(socket, scope, draft) do
    case connected?(socket) do
      true ->
        case DraftSession.join(draft.id, scope, scope.user.id) do
          {:ok, joined_draft, _seq, undo_state, editor_state} ->
            {:ok, joined_draft, undo_state, editor_state, true}

          {:error, reason} ->
            {:error, reason}
        end

      false ->
        {:ok, draft, empty_undo_state(), initial_editor_state(nil), false}
    end
  end

  defp load_selected_revision(
         %{assigns: %{current_draft: %WorkflowDefinitionVersion{} = current_draft}} = socket,
         params
       ) do
    {selected_revision, selected_draft} =
      case Map.get(params, "kind") do
        "undo" ->
          select_undo_revision(socket, params)

        "version" ->
          select_version_revision(socket, params)

        _kind ->
          current_revision(current_draft)
      end

    socket
    |> assign(:selected_revision, selected_revision)
    |> assign(:selected_draft, selected_draft)
    |> assign(:selected_draft_payload, Payload.draft(selected_draft))
  end

  defp load_selected_revision(socket, _params), do: socket

  defp select_undo_revision(socket, params) do
    with {:ok, depth} <- parse_positive_integer(Map.get(params, "depth")),
         {:ok, undo_entry} <- fetch_undo_entry(socket.assigns.undo_stack, depth),
         true <- socket.assigns.draft_session_joined?,
         {:ok, preview_draft} <-
           DraftSession.preview_revision(
             socket.assigns.current_draft.id,
             socket.assigns.current_user_id,
             {:undo, depth}
           ) do
      revision = %{
        "kind" => "undo",
        "label" => undo_revision_label(undo_entry),
        "depth" => depth
      }

      {revision, preview_draft}
    else
      _error ->
        current_revision(socket.assigns.current_draft)
    end
  end

  defp select_version_revision(socket, params) do
    version_id = Map.get(params, "id")

    case load_version_revision(socket, version_id) do
      {:ok, %WorkflowDefinitionVersion{} = version} ->
        revision = %{
          "kind" => "version",
          "label" => "Version v#{version.version}",
          "id" => version.id
        }

        {revision, version}

      {:error, _reason} ->
        current_revision(socket.assigns.current_draft)
    end
  end

  defp apply_selected_revision(
         %{
           assigns: %{
             current_draft: %WorkflowDefinitionVersion{} = current_draft,
             selected_draft: %WorkflowDefinitionVersion{} = selected_draft,
             current_user_id: current_user_id
           }
         } = socket
       )
       when is_binary(current_user_id) do
    case same_snapshot?(current_draft, selected_draft) do
      true ->
        {:ok, socket}

      false ->
        operation = %{
          type: :restore_snapshot,
          params: %{
            snapshot: Payload.snapshot_attrs(selected_draft),
            label: applied_revision_label(socket.assigns.selected_revision)
          }
        }

        case DraftSession.apply_operation(current_draft.id, current_user_id, operation) do
          {:ok, updated_draft, _seq, undo_state} ->
            updated_socket =
              socket
              |> assign(:current_draft, updated_draft)
              |> assign(:selected_draft, updated_draft)
              |> assign(:selected_draft_payload, Payload.draft(updated_draft))
              |> assign(:selected_revision, %{"kind" => "current", "label" => "Current draft"})
              |> assign(
                :workflow,
                Payload.workflow(
                  socket.assigns.definition,
                  updated_draft,
                  socket.assigns.project_name
                )
              )
              |> assign(:undo_stack, Map.get(undo_state, :undoStack, []))

            {:ok, updated_socket}

          {:error, reason} ->
            {:error, put_flash(socket, :error, "Could not apply revision: #{inspect(reason)}")}
        end
    end
  end

  defp apply_selected_revision(socket),
    do: {:error, put_flash(socket, :error, "Could not apply revision")}

  defp current_revision(%WorkflowDefinitionVersion{} = current_draft) do
    {%{"kind" => "current", "label" => "Current draft"}, current_draft}
  end

  defp load_version_revision(
         %{
           assigns: %{
             current_draft: %WorkflowDefinitionVersion{} = current_draft,
             current_user_id: current_user_id,
             draft_session_joined?: true
           }
         },
         version_id
       )
       when is_binary(current_user_id) and is_binary(version_id) do
    DraftSession.preview_revision(current_draft.id, current_user_id, {:version, version_id})
  end

  defp load_version_revision(
         %{assigns: %{current_scope: scope, definition: definition}},
         version_id
       )
       when is_binary(version_id) do
    with {:ok, version} <- Workflows.get_version(scope, version_id),
         :ok <- ensure_version_matches_definition(definition, version),
         :ok <- ensure_published_version(version) do
      {:ok, version}
    end
  end

  defp load_version_revision(_socket, _version_id), do: {:error, :revision_not_found}

  defp ensure_version_matches_definition(
         %{id: definition_id},
         %WorkflowDefinitionVersion{workflow_definition_id: definition_id}
       ),
       do: :ok

  defp ensure_version_matches_definition(_definition, %WorkflowDefinitionVersion{}),
    do: {:error, :revision_not_found}

  defp ensure_published_version(%WorkflowDefinitionVersion{status: :published}), do: :ok
  defp ensure_published_version(%WorkflowDefinitionVersion{}), do: {:error, :revision_not_found}

  defp fetch_undo_entry(undo_stack, depth) when is_list(undo_stack) do
    case Enum.find(undo_stack, &(Map.get(&1, :depth) == depth or Map.get(&1, "depth") == depth)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp fetch_undo_entry(_undo_stack, _depth), do: {:error, :not_found}

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {depth, ""} when depth > 0 -> {:ok, depth}
      _ -> {:error, :invalid_depth}
    end
  end

  defp parse_positive_integer(_value), do: {:error, :invalid_depth}

  defp undo_revision_label(entry) do
    case Map.get(entry, :label) || Map.get(entry, "label") do
      label when is_binary(label) and label != "" -> label
      _ -> "Undo #{Map.get(entry, :depth) || Map.get(entry, "depth")}"
    end
  end

  defp applied_revision_label(%{"kind" => "undo", "depth" => depth}) when is_integer(depth),
    do: "Apply Undo #{depth}"

  defp applied_revision_label(%{"kind" => "version", "label" => label}) when is_binary(label),
    do: "Apply #{label}"

  defp applied_revision_label(_revision), do: "Apply Revision"

  defp same_snapshot?(%WorkflowDefinitionVersion{} = left, %WorkflowDefinitionVersion{} = right) do
    Payload.snapshot_attrs(left) == Payload.snapshot_attrs(right)
  end

  defp same_snapshot?(_left, _right), do: false

  defp empty_undo_state do
    %{
      canUndo: false,
      canRedo: false,
      undoLabel: nil,
      redoLabel: nil,
      undoStack: [],
      redoStack: []
    }
  end

  defp initial_editor_state(workflow_id) do
    %{
      workflow_id: workflow_id,
      pinned_outputs: %{},
      disabled_steps: [],
      step_locks: %{}
    }
  end

  defp current_user_id(socket) do
    case socket.assigns.current_scope do
      %{user: %{id: user_id}} when is_binary(user_id) -> user_id
      _ -> nil
    end
  end

  defp maybe_leave_draft_session(%{
         assigns: %{
           current_draft: %WorkflowDefinitionVersion{id: version_id},
           current_user_id: user_id
         }
       })
       when is_binary(version_id) and is_binary(user_id) do
    maybe_persist_before_leave(version_id)
    _ = DraftSession.leave(version_id, user_id)
    :ok
  end

  defp maybe_leave_draft_session(_socket), do: :ok

  defp maybe_persist_before_leave(version_id) do
    case DraftSession.get_persistence_state(version_id) do
      {:ok, %{status: :saved}} ->
        :ok

      {:ok, _persistence} ->
        _ = DraftSession.persist_now(version_id)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp redirect_with_error(socket, message, to) do
    socket
    |> put_flash(:error, message)
    |> redirect(to: to)
  end

  defp edit_workflow_path(socket) do
    ~p"/projects/#{socket.assigns.project_id}/workflows/#{socket.assigns.definition_id}/edit"
  end

  defp revision_workflow_path(socket) do
    ~p"/projects/#{socket.assigns.project_id}/workflows/#{socket.assigns.definition_id}/edit/revisions"
  end

  defp revision_workflow_path(socket, payload) when is_map(payload) do
    case Map.get(payload, "kind") || Map.get(payload, :kind) do
      "undo" ->
        case parse_positive_integer(Map.get(payload, "depth") || Map.get(payload, :depth)) do
          {:ok, depth} ->
            ~p"/projects/#{socket.assigns.project_id}/workflows/#{socket.assigns.definition_id}/edit/revisions?#{[kind: "undo", depth: depth]}"

          {:error, _reason} ->
            revision_workflow_path(socket)
        end

      "version" ->
        case Map.get(payload, "id") || Map.get(payload, :id) do
          version_id when is_binary(version_id) and version_id != "" ->
            ~p"/projects/#{socket.assigns.project_id}/workflows/#{socket.assigns.definition_id}/edit/revisions?#{[kind: "version", id: version_id]}"

          _version_id ->
            revision_workflow_path(socket)
        end

      _kind ->
        revision_workflow_path(socket)
    end
  end
end
