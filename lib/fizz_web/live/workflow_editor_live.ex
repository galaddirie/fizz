defmodule FizzWeb.WorkflowEditorLive do
  use Phoenix.LiveView
  use LiveVue, :live_view
  use FizzWeb, :verified_routes

  alias Fizz.Accounts
  alias Fizz.Steps
  alias Fizz.Steps.Type
  alias Fizz.Workflows
  alias Fizz.Workflows.DraftSession
  alias Fizz.Workflows.Expressions
  alias Fizz.Workflows.WorkflowDefinition
  alias Fizz.Workflows.WorkflowDefinitionVersion
  alias Fizz.Workflows.WorkflowRun
  alias Fizz.Workflows.Embeds.{Connection, Step, StepGroup}
  alias FizzWeb.Layouts
  alias FizzWeb.Presence
  alias Phoenix.Socket.Broadcast

  @presence_throttle_ms 60
  @preview_debounce_ms 150

  @structural_command_types ~w(
    add_step
    remove_step
    update_step
    move_step
    move_steps
    add_connection
    remove_connection
    add_group
    update_group
    remove_group
    set_group_membership
    commit_drag_layout
    duplicate_steps
    tidy_layout
  )

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign_defaults(params)
      |> load_editor(params)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :workflow, workflow_prop(assigns))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @workflow do %>
        <.vue
          id="workflow-editor"
          v-component="WorkflowEditor"
          v-socket={@socket}
          workflow={@workflow}
          stepTypes={@step_types}
          nodeLibraryItems={@node_library_items}
          execution={@execution}
          stepExecutions={@step_executions}
          editorState={@editor_state}
          undoState={@undo_state}
          presences={@presences}
          currentUserId={@current_user_id}
          collabSeq={@collab_seq}
          expressionPreviews={@expression_previews}
          credentialOptions={@credential_options}
          debugExecutionId={@debug_execution_id}
        />
      <% else %>
        <div id="workflow-editor-loading" />
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("editor_command", %{"type" => type} = params, socket) do
    payload =
      case Map.get(params, "payload", %{}) do
        payload when is_map(payload) -> payload
        _ -> %{}
      end

    case type do
      type when type in @structural_command_types ->
        {:noreply, apply_structural_operation(socket, type, payload)}

      "undo" ->
        {:noreply, undo_operation(socket)}

      "redo" ->
        {:noreply, redo_operation(socket)}

      "mouse_move" ->
        {:noreply, update_presence_cursor(socket, payload)}

      "selection_changed" ->
        {:noreply, update_presence_selection(socket, payload)}

      "preview_expression" ->
        {:noreply, schedule_expression_preview(socket, payload)}

      "save_workflow" ->
        {:noreply, persist_draft(socket)}

      "publish_workflow" ->
        {:noreply, put_flash(socket, :info, "Publishing is wired in Phase 5.")}

      "run_test" ->
        {:noreply, put_flash(socket, :info, "Execution controls are wired in Phase 4.")}

      "run_node" ->
        {:noreply, put_flash(socket, :info, "Execution controls are wired in Phase 4.")}

      "cancel_execution" ->
        {:noreply, put_flash(socket, :info, "Execution controls are wired in Phase 4.")}

      "pin_output" ->
        {:noreply, pin_output(socket, payload)}

      "unpin_output" ->
        {:noreply, unpin_output(socket, payload)}

      "disable_step" ->
        {:noreply, disable_step(socket, payload)}

      "enable_step" ->
        {:noreply, enable_step(socket, payload)}

      "navigate_revisions" ->
        {:noreply, put_flash(socket, :info, "Revision navigation is not wired yet.")}

      _unsupported ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:draft_updated, seq, _summary}, socket) do
    if seq > socket.assigns.collab_seq do
      {:noreply, refresh_draft_state(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:draft_persisted, _seq}, socket) do
    {:noreply, refresh_draft_state(socket)}
  end

  def handle_info(
        {:operation_rejected, user_id, reason},
        %{assigns: %{current_user_id: user_id}} = socket
      ) do
    {:noreply,
     push_event(socket, "workflow:operation_rejected", %{reason: encode_reason(reason)})}
  end

  def handle_info({:operation_rejected, _user_id, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_info(
        {:undo_rejected, user_id, _reason},
        %{assigns: %{current_user_id: user_id}} = socket
      ) do
    {:noreply,
     socket
     |> refresh_undo_state()
     |> push_event("workflow:undo_conflict", %{})}
  end

  def handle_info({:undo_rejected, _user_id, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_info(
        {:preview_expression, key, expression, ref},
        %{assigns: %{preview_timers: preview_timers}} = socket
      ) do
    if Map.get(preview_timers, key) == ref do
      {:noreply,
       socket
       |> update(:preview_timers, &Map.delete(&1, key))
       |> update(:expression_previews, &Map.put(&1, key, preview_expression_value(expression)))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Broadcast{event: "presence_diff", topic: topic},
        %{assigns: %{draft_topic: topic}} = socket
      ) do
    {:noreply, assign(socket, :presences, presence_entries(topic))}
  end

  def handle_info(
        %Broadcast{topic: "workflow_run:" <> run_id},
        %{assigns: %{debug_execution_id: run_id}} = socket
      ) do
    {:noreply, refresh_execution(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    maybe_leave_draft_session(socket)
    :ok
  end

  defp assign_defaults(socket, params) do
    project_id = Map.get(params, "project_id")
    definition_id = Map.get(params, "definition_id")
    run_id = Map.get(params, "run_id")
    current_user_id = current_user_id(socket)

    socket
    |> assign(:project_id, project_id)
    |> assign(:definition_id, definition_id)
    |> assign(:run_id, run_id)
    |> assign(:project_name, nil)
    |> assign(:page_title, "Workflow Editor")
    |> assign(:definition, nil)
    |> assign(:draft, nil)
    |> assign(:draft_topic, nil)
    |> assign(:run_topic, nil)
    |> assign(:step_types, [])
    |> assign(:node_library_items, [])
    |> assign(:collab_seq, 0)
    |> assign(:presences, [])
    |> assign(:editor_state, initial_editor_state(nil))
    |> assign(:execution, nil)
    |> assign(:step_executions, [])
    |> assign(:expression_previews, %{})
    |> assign(:undo_state, empty_undo_state())
    |> assign(:credential_options, [])
    |> assign(:debug_execution_id, nil)
    |> assign(:current_user_id, current_user_id)
    |> assign(:last_presence_update_at_ms, 0)
    |> assign(:preview_timers, %{})
  end

  defp load_editor(
         socket,
         %{"project_id" => project_id, "definition_id" => definition_id} = params
       ) do
    run_id = Map.get(params, "run_id")

    with {:ok, scope} <-
           Accounts.build_scope_for_project(socket.assigns.current_scope, project_id),
         {:ok, definition} <- Workflows.get_definition(scope, definition_id),
         {:ok, draft} <- Workflows.edit_definition(scope, definition_id),
         {:ok, execution} <- load_execution(scope, run_id, socket.assigns.live_action),
         {:ok, socket, draft, seq, undo_state, presences} <-
           maybe_connect_draft_session(socket, scope, draft, run_id) do
      step_types = Steps.list_types()

      socket
      |> assign(:current_scope, scope)
      |> assign(:project_name, scope.project.name)
      |> assign(:page_title, definition.name || "Workflow Editor")
      |> assign(:definition, definition)
      |> assign(:draft, draft)
      |> assign(:step_types, Enum.map(step_types, &encode_step_type/1))
      |> assign(:node_library_items, Enum.map(step_types, &encode_node_library_item/1))
      |> assign(:collab_seq, seq)
      |> assign(:presences, presences)
      |> assign(:editor_state, initial_editor_state(definition.id))
      |> assign(:execution, execution)
      |> assign(:step_executions, [])
      |> assign(:undo_state, undo_state)
      |> assign(:credential_options, [])
      |> assign(
        :debug_execution_id,
        if(socket.assigns.live_action == :debug, do: run_id, else: nil)
      )
      |> maybe_push_undo_state()
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

      {:error, :run_not_found} ->
        redirect_with_error(
          socket,
          "Workflow run not found",
          ~p"/projects/#{project_id}/workflows/#{definition_id}/edit"
        )

      {:error, reason} ->
        redirect_with_error(
          socket,
          "Could not load workflow editor: #{inspect(reason)}",
          ~p"/projects"
        )
    end
  end

  defp load_editor(socket, _params),
    do: redirect_with_error(socket, "Workflow not found", ~p"/projects")

  defp maybe_connect_draft_session(socket, scope, draft, run_id) do
    if connected?(socket) do
      user_id = scope.user.id
      draft_topic = draft_topic(draft.id)
      run_topic = run_topic(run_id)

      with {:ok, joined_draft, seq, undo_state} <- DraftSession.join(draft.id, scope, user_id),
           :ok <- Phoenix.PubSub.subscribe(Fizz.PubSub, draft_topic),
           :ok <- maybe_subscribe_to_run_topic(run_topic),
           {:ok, _meta} <-
             Presence.track(self(), draft_topic, user_id, initial_presence_meta(scope.user)) do
        {:ok,
         socket
         |> assign(:draft_topic, draft_topic)
         |> assign(:run_topic, run_topic), joined_draft, seq, undo_state,
         presence_entries(draft_topic)}
      else
        {:error, {:already_tracked, _pid}} ->
          {:ok,
           socket
           |> assign(:draft_topic, draft_topic)
           |> assign(:run_topic, run_topic), draft, 0, empty_undo_state(),
           presence_entries(draft_topic)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, socket, draft, 0, empty_undo_state(), []}
    end
  end

  defp maybe_subscribe_to_run_topic(nil), do: :ok
  defp maybe_subscribe_to_run_topic(topic), do: Phoenix.PubSub.subscribe(Fizz.PubSub, topic)

  defp load_execution(_scope, _run_id, :edit), do: {:ok, nil}
  defp load_execution(_scope, nil, :debug), do: {:ok, nil}

  defp load_execution(scope, run_id, :debug) when is_binary(run_id) do
    case Workflows.get_run(scope, run_id) do
      {:ok, run} -> {:ok, encode_execution(run)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_structural_operation(socket, type, payload) do
    with {:ok, draft, seq, undo_state} <-
           DraftSession.apply_operation(
             socket.assigns.draft.id,
             socket.assigns.current_user_id,
             %{
               type: type,
               params: payload
             }
           ) do
      socket
      |> assign_draft_state(draft, seq, undo_state)
      |> push_event("workflow:operation_ack", %{type: type, seq: seq})
    else
      {:error, _reason} ->
        socket
    end
  end

  defp undo_operation(socket) do
    case DraftSession.undo(socket.assigns.draft.id, socket.assigns.current_user_id) do
      {:ok, draft, seq, undo_state} ->
        socket
        |> assign_draft_state(draft, seq, undo_state)
        |> push_event("workflow:undo_applied", %{})
        |> push_event("workflow:operation_ack", %{type: "undo", seq: seq})

      {:error, _reason} ->
        socket
        |> refresh_undo_state()
        |> push_event("workflow:undo_conflict", %{})
    end
  end

  defp redo_operation(socket) do
    case DraftSession.redo(socket.assigns.draft.id, socket.assigns.current_user_id) do
      {:ok, draft, seq, undo_state} ->
        socket
        |> assign_draft_state(draft, seq, undo_state)
        |> push_event("workflow:redo_applied", %{})
        |> push_event("workflow:operation_ack", %{type: "redo", seq: seq})

      {:error, _reason} ->
        socket
        |> refresh_undo_state()
        |> push_event("workflow:redo_conflict", %{})
    end
  end

  defp persist_draft(socket) do
    case DraftSession.persist_now(socket.assigns.draft.id) do
      {:ok, draft, seq} ->
        socket
        |> assign(:draft, draft)
        |> assign(:collab_seq, seq)
        |> push_event("workflow:operation_ack", %{type: "save_workflow", seq: seq})

      {:error, reason} ->
        put_flash(socket, :error, "Could not save workflow: #{inspect(reason)}")
    end
  end

  defp update_presence_cursor(socket, payload) do
    now = System.monotonic_time(:millisecond)

    if now - socket.assigns.last_presence_update_at_ms < @presence_throttle_ms do
      socket
    else
      update_presence(socket, %{
        cursor: cursor_from_payload(payload),
        dragging_steps: payload_value(payload, "dragging_steps"),
        dragging_groups: payload_value(payload, "dragging_groups")
      })
      |> assign(:last_presence_update_at_ms, now)
    end
  end

  defp update_presence_selection(socket, payload) do
    selected_steps =
      payload
      |> payload_value("step_ids")
      |> string_list()

    update_presence(socket, %{
      selected_steps: selected_steps,
      focused_step: focused_step(selected_steps)
    })
  end

  defp update_presence(socket, changes) do
    case Presence.update(
           self(),
           socket.assigns.draft_topic,
           socket.assigns.current_user_id,
           &Map.merge(&1, changes)
         ) do
      {:ok, _meta} ->
        assign(socket, :presences, presence_entries(socket.assigns.draft_topic))

      {:error, _reason} ->
        socket
    end
  end

  defp schedule_expression_preview(socket, payload) do
    key = preview_key(payload)

    case key do
      nil ->
        socket

      key ->
        if timer_ref = Map.get(socket.assigns.preview_timers, key) do
          Process.cancel_timer(timer_ref)
        end

        expression = Map.get(payload, "expression") || Map.get(payload, :expression) || ""
        timer_ref = make_ref()

        Process.send_after(
          self(),
          {:preview_expression, key, expression, timer_ref},
          @preview_debounce_ms
        )

        assign(socket, :preview_timers, Map.put(socket.assigns.preview_timers, key, timer_ref))
    end
  end

  defp pin_output(socket, payload) do
    step_id = Map.get(payload, "step_id") || Map.get(payload, :step_id)

    if is_binary(step_id) and has_payload_key?(payload, "output_data", :output_data) do
      output_data =
        Map.get(payload, "output_data", Map.get(payload, :output_data))

      update(socket, :editor_state, fn editor_state ->
        %{
          editor_state
          | pinned_outputs: Map.put(editor_state.pinned_outputs, step_id, output_data)
        }
      end)
    else
      socket
    end
  end

  defp unpin_output(socket, payload) do
    step_id = Map.get(payload, "step_id") || Map.get(payload, :step_id)

    if is_binary(step_id) do
      update(socket, :editor_state, fn editor_state ->
        %{editor_state | pinned_outputs: Map.delete(editor_state.pinned_outputs, step_id)}
      end)
    else
      socket
    end
  end

  defp disable_step(socket, payload) do
    step_id = Map.get(payload, "step_id") || Map.get(payload, :step_id)

    if is_binary(step_id) do
      update(socket, :editor_state, fn editor_state ->
        %{editor_state | disabled_steps: Enum.uniq([step_id | editor_state.disabled_steps])}
      end)
    else
      socket
    end
  end

  defp enable_step(socket, payload) do
    step_id = Map.get(payload, "step_id") || Map.get(payload, :step_id)

    if is_binary(step_id) do
      update(socket, :editor_state, fn editor_state ->
        %{
          editor_state
          | disabled_steps: Enum.reject(editor_state.disabled_steps, &(&1 == step_id))
        }
      end)
    else
      socket
    end
  end

  defp refresh_draft_state(socket) do
    case DraftSession.join(
           socket.assigns.draft.id,
           socket.assigns.current_scope,
           socket.assigns.current_user_id
         ) do
      {:ok, draft, seq, undo_state} ->
        socket
        |> assign_draft_state(draft, seq, undo_state)
        |> assign(:presences, presence_entries(socket.assigns.draft_topic))

      {:error, _reason} ->
        socket
    end
  end

  defp refresh_undo_state(socket) do
    case DraftSession.get_undo_state(socket.assigns.draft.id, socket.assigns.current_user_id) do
      {:ok, undo_state} ->
        socket
        |> assign(:undo_state, undo_state)
        |> maybe_push_undo_state()

      {:error, _reason} ->
        socket
    end
  end

  defp refresh_execution(socket) do
    case Workflows.get_run(socket.assigns.current_scope, socket.assigns.debug_execution_id) do
      {:ok, run} -> assign(socket, :execution, encode_execution(run))
      {:error, _reason} -> socket
    end
  end

  defp assign_draft_state(socket, draft, seq, undo_state) do
    socket
    |> assign(:draft, draft)
    |> assign(:collab_seq, seq)
    |> assign(:undo_state, undo_state)
    |> maybe_push_undo_state()
  end

  defp maybe_push_undo_state(socket) do
    if connected?(socket) do
      push_event(socket, "workflow:undo_state", socket.assigns.undo_state)
    else
      socket
    end
  end

  defp maybe_leave_draft_session(%{
         assigns: %{draft: %WorkflowDefinitionVersion{id: version_id}, current_user_id: user_id}
       })
       when is_binary(version_id) and is_binary(user_id) do
    _ = DraftSession.leave(version_id, user_id)
    :ok
  end

  defp maybe_leave_draft_session(_socket), do: :ok

  defp redirect_with_error(socket, message, to) do
    socket
    |> put_flash(:error, message)
    |> redirect(to: to)
  end

  defp workflow_prop(assigns) do
    definition = Map.get(assigns, :definition)
    draft = Map.get(assigns, :draft)

    case {definition, draft} do
      {%WorkflowDefinition{} = definition, %WorkflowDefinitionVersion{} = draft} ->
        %{
          id: definition.id,
          project_id: definition.project_id,
          name: definition.name,
          description: definition.description,
          status: workflow_status(definition),
          public: false,
          current_version_tag: version_tag(draft),
          published_version_id: published_version_id(definition),
          user_id: definition.created_by_user_id,
          inserted_at: encode_datetime(definition.inserted_at),
          updated_at: encode_datetime(definition.updated_at),
          draft: encode_draft(draft, definition.id),
          project: %{name: Map.get(assigns, :project_name)}
        }

      _ ->
        nil
    end
  end

  defp workflow_status(%WorkflowDefinition{archived_at: nil}), do: "draft"
  defp workflow_status(%WorkflowDefinition{}), do: "archived"

  defp version_tag(%WorkflowDefinitionVersion{version: version}) when is_integer(version) do
    Integer.to_string(version)
  end

  defp version_tag(_draft), do: nil

  defp published_version_id(%WorkflowDefinition{versions: versions}) when is_list(versions) do
    versions
    |> Enum.find(&(&1.status == :published))
    |> case do
      %WorkflowDefinitionVersion{id: id} -> id
      nil -> nil
    end
  end

  defp published_version_id(_definition), do: nil

  defp encode_draft(%WorkflowDefinitionVersion{} = draft, workflow_id) do
    %{
      id: draft.id,
      workflow_id: workflow_id,
      steps: Enum.map(draft.steps, &encode_step/1),
      connections: Enum.map(draft.connections, &encode_connection/1),
      groups: Enum.map(draft.step_groups, &encode_group/1),
      triggers: [],
      settings: draft.settings || %{},
      viewport: draft.viewport || %{},
      inserted_at: encode_datetime(draft.inserted_at),
      updated_at: encode_datetime(draft.updated_at)
    }
  end

  defp encode_step(%Step{} = step) do
    %{
      id: step.id,
      type_id: step.type_id,
      name: step.name,
      config: step.config || %{},
      position: step.position || %{},
      notes: step.notes
    }
  end

  defp encode_connection(%Connection{} = connection) do
    %{
      id: connection.id,
      source_step_id: connection.source_step_id,
      source_output: connection.source_output,
      target_step_id: connection.target_step_id,
      target_input: connection.target_input
    }
  end

  defp encode_group(%StepGroup{} = group) do
    %{
      id: group.id,
      name: group.name,
      step_ids: group.step_ids || [],
      output_step_id: List.first(group.step_ids),
      position: group.position || %{},
      color: group.color,
      font_size: group.font_size,
      collapsed: group.collapsed
    }
  end

  defp encode_step_type(%Type{} = type) do
    %{
      id: type.id,
      name: type.name,
      description: type.description,
      category: type.category,
      icon: type.icon,
      step_kind: Atom.to_string(type.step_kind),
      node_role: Atom.to_string(type.node_role),
      config_schema: type.config_schema || %{},
      input_schema: type.input_schema || %{},
      output_schema: type.output_schema || %{},
      subnode_slots: type.subnode_slots || []
    }
  end

  defp encode_node_library_item(%Type{} = type) do
    %{
      type_id: type.id,
      name: type.name,
      description: type.description,
      icon: type.icon,
      category: type.category,
      step_kind: Atom.to_string(type.step_kind),
      node_role: Atom.to_string(type.node_role)
    }
  end

  defp encode_execution(%WorkflowRun{} = run) do
    %{
      id: run.id,
      workflow_id: run.workflow_definition_id,
      workflow_version_id: run.workflow_definition_version_id,
      status: encode_execution_status(run.status),
      execution_type: "production",
      trigger: %{
        type: trigger_type(run.triggered_by),
        data: run.triggered_by || %{}
      },
      context: run.input || %{},
      output: run.output,
      error: encode_execution_error(run.error),
      metadata: %{},
      triggered_by_user_id: triggered_by_user_id(run.triggered_by),
      started_at: encode_datetime(run.started_at),
      completed_at: encode_datetime(run.completed_at),
      inserted_at: encode_datetime(run.inserted_at),
      updated_at: encode_datetime(run.updated_at)
    }
  end

  defp encode_execution_status(:pending), do: "pending"
  defp encode_execution_status(:running), do: "running"
  defp encode_execution_status(:sleeping), do: "paused"
  defp encode_execution_status(:passivated), do: "paused"
  defp encode_execution_status(:completed), do: "completed"
  defp encode_execution_status(:failed), do: "failed"
  defp encode_execution_status(:cancelled), do: "cancelled"
  defp encode_execution_status(:continued), do: "completed"
  defp encode_execution_status(status) when is_binary(status), do: status
  defp encode_execution_status(status), do: Atom.to_string(status)

  defp trigger_type(%{} = triggered_by) do
    Map.get(triggered_by, :type) || Map.get(triggered_by, "type") || "manual"
  end

  defp trigger_type(_triggered_by), do: "manual"

  defp triggered_by_user_id(%{} = triggered_by) do
    Map.get(triggered_by, :user_id) || Map.get(triggered_by, "user_id")
  end

  defp triggered_by_user_id(_triggered_by), do: nil

  defp encode_execution_error(nil), do: nil

  defp encode_execution_error(%{} = error) do
    %{
      type: Map.get(error, :type) || Map.get(error, "type") || "runtime_error",
      message: Map.get(error, :message) || Map.get(error, "message") || inspect(error),
      details: error
    }
  end

  defp encode_execution_error(error) do
    %{type: "runtime_error", message: inspect(error), details: %{}}
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_datetime(value), do: value

  defp initial_editor_state(workflow_id) do
    %{
      workflow_id: workflow_id,
      pinned_outputs: %{},
      disabled_steps: [],
      step_locks: %{}
    }
  end

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

  defp draft_topic(version_id), do: "draft:#{version_id}"
  defp run_topic(nil), do: nil
  defp run_topic(run_id), do: "workflow_run:#{run_id}"

  defp initial_presence_meta(user) do
    %{
      user_id: user.id,
      user_name: user.email,
      user_email: user.email,
      cursor: nil,
      selected_steps: [],
      focused_step: nil,
      dragging_steps: nil,
      dragging_groups: nil
    }
  end

  defp presence_entries(nil), do: []

  defp presence_entries(topic) do
    topic
    |> Presence.list()
    |> Enum.map(fn {user_id, %{metas: metas}} ->
      meta = List.last(metas) || %{}

      %{
        user: %{
          id: Map.get(meta, :user_id, user_id),
          name: Map.get(meta, :user_name),
          email: Map.get(meta, :user_email)
        },
        cursor: Map.get(meta, :cursor),
        selected_steps: Map.get(meta, :selected_steps, []),
        focused_step: Map.get(meta, :focused_step),
        dragging_steps: Map.get(meta, :dragging_steps),
        dragging_groups: Map.get(meta, :dragging_groups)
      }
    end)
    |> Enum.sort_by(&get_in(&1, [:user, :id]))
  end

  defp cursor_from_payload(payload) do
    x = Map.get(payload, "x") || Map.get(payload, :x)
    y = Map.get(payload, "y") || Map.get(payload, :y)

    if is_number(x) and is_number(y) do
      %{x: x, y: y}
    else
      nil
    end
  end

  defp payload_value(payload, string_key) do
    Map.get(payload, string_key) || Map.get(payload, String.to_existing_atom(string_key))
  rescue
    ArgumentError -> Map.get(payload, string_key)
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp string_list(_values), do: []

  defp focused_step([step_id]), do: step_id
  defp focused_step(_step_ids), do: nil

  defp preview_key(payload) do
    step_id = Map.get(payload, "step_id") || Map.get(payload, :step_id)
    field_key = Map.get(payload, "field_key") || Map.get(payload, :field_key)

    if is_binary(step_id) and is_binary(field_key) do
      "#{step_id}:#{field_key}"
    else
      nil
    end
  end

  defp preview_expression_value(expression) do
    case Expressions.validate(expression) do
      {:ok, _parsed} ->
        ""

      {:error, errors} ->
        %{
          type: "parse_error",
          errors: errors,
          text: expression
        }
    end
  rescue
    error ->
      %{
        type: "render_error",
        message: Exception.message(error),
        text: expression
      }
  end

  defp current_user_id(socket) do
    case socket.assigns.current_scope do
      %{user: %{id: user_id}} when is_binary(user_id) -> user_id
      _ -> nil
    end
  end

  defp encode_reason(reason) when is_binary(reason), do: reason
  defp encode_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp encode_reason(reason), do: inspect(reason)

  defp has_payload_key?(payload, string_key, atom_key) do
    Map.has_key?(payload, string_key) or Map.has_key?(payload, atom_key)
  end
end
