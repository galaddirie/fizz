defmodule FizzWeb.WorkflowEditorLive do
  use Phoenix.LiveView
  use LiveVue, :live_view
  use FizzWeb, :verified_routes

  alias Fizz.Accounts
  alias Fizz.Integrations.CredentialsResolver
  alias Fizz.Steps
  alias Fizz.Steps.Executors.Behaviour, as: StepExecutorBehaviour
  alias Fizz.Steps.Type
  alias Fizz.Triggers
  alias Fizz.Workflows
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.DraftValidator
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
  @preview_debounce_ms 300

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
          validationErrors={@validation_errors}
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

      "search_credentials" ->
        {:noreply, search_credentials(socket, payload)}

      "save_workflow" ->
        {:noreply, persist_draft(socket)}

      "validate_draft" ->
        {:noreply, validate_draft(socket)}

      "publish_workflow" ->
        {:noreply, publish_workflow(socket)}

      "run_test" ->
        {:noreply, run_test(socket)}

      "run_node" ->
        {:noreply, put_flash(socket, :info, "Execution controls are wired in Phase 4.")}

      "cancel_execution" ->
        {:noreply, cancel_execution(socket)}

      "load_step_io" ->
        {:noreply, load_step_io(socket, payload)}

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
  def handle_event("resolve_field_options", payload, socket) do
    case resolve_field_options(socket, payload) do
      {:ok, socket, options} ->
        {:reply, %{options: options}, socket}

      {:error, socket, reason} ->
        {:reply, %{options: [], error: encode_reason(reason)}, socket}
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
        {:preview_expression, key, step_id, expression, ref},
        %{assigns: %{preview_timers: preview_timers}} = socket
      ) do
    case Map.get(preview_timers, key) do
      ^ref ->
        preview_context =
          build_preview_context(
            step_id,
            socket.assigns.draft,
            socket.assigns.editor_state,
            socket.assigns.step_executions
          )
          |> Map.put("workflow", workflow_preview_context(socket.assigns.definition))

        {:noreply,
         socket
         |> update(:preview_timers, &Map.delete(&1, key))
         |> update(
           :expression_previews,
           &Map.put(&1, key, preview_expression_value(expression, preview_context))
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(
        %Broadcast{event: "presence_diff", topic: topic},
        %{assigns: %{draft_topic: topic}} = socket
      ) do
    {:noreply, assign(socket, :presences, presence_entries(topic))}
  end

  def handle_info({:step_started, %{run_id: run_id} = payload}, socket) do
    {:noreply, maybe_apply_step_started(socket, run_id, payload)}
  end

  def handle_info({:step_completed, %{run_id: run_id} = payload}, socket) do
    {:noreply, maybe_apply_step_completed(socket, run_id, payload)}
  end

  def handle_info({:step_failed, %{run_id: run_id} = payload}, socket) do
    {:noreply, maybe_apply_step_failed(socket, run_id, payload)}
  end

  def handle_info({:run_status_changed, %{run_id: run_id, status: status} = payload}, socket) do
    {:noreply, maybe_apply_run_status(socket, run_id, status, payload)}
  end

  def handle_info(
        %Broadcast{topic: "workflow_run:" <> run_id},
        %{assigns: %{debug_execution_id: run_id}} = socket
      ) do
    {:noreply, refresh_execution_state(socket, run_id)}
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
    |> assign(:validation_errors, %{})
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
         {:ok, execution, step_executions, debug_execution_id} <-
           load_execution(scope, run_id, socket.assigns.live_action),
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
      |> assign(:step_executions, step_executions)
      |> assign(:undo_state, undo_state)
      |> assign(:credential_options, [])
      |> assign(:debug_execution_id, debug_execution_id)
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

  defp load_execution(_scope, _run_id, :edit), do: {:ok, nil, [], nil}
  defp load_execution(_scope, nil, :debug), do: {:ok, nil, [], nil}

  defp load_execution(scope, run_id, :debug) when is_binary(run_id) do
    with {:ok, run} <- Workflows.get_run(scope, run_id),
         {:ok, step_executions} <- Workflows.list_run_step_executions(scope, run_id) do
      {:ok, encode_execution(run), step_executions, run_id}
    else
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
        |> clear_validation_errors()
        |> push_event("workflow:operation_ack", %{type: "save_workflow", seq: seq})

      {:error, reason} ->
        put_flash(socket, :error, "Could not save workflow: #{inspect(reason)}")
    end
  end

  defp validate_draft(socket) do
    draft = socket.assigns.draft
    scope = socket.assigns.current_scope
    trigger_impact = compute_trigger_impact(draft, scope)

    case DraftValidator.validate_for_publish(draft, scope) do
      :ok ->
        socket
        |> clear_validation_errors()
        |> push_event("workflow:validation_result", %{
          valid: true,
          validation_errors: [],
          trigger_impact: trigger_impact
        })

      {:error, errors} ->
        socket
        |> assign(:validation_errors, validation_error_map(errors))
        |> push_event("workflow:validation_result", %{
          valid: false,
          validation_errors: Enum.map(errors, &encode_validation_error/1),
          trigger_impact: trigger_impact
        })
    end
  end

  defp publish_workflow(socket) do
    version_id = socket.assigns.draft.id
    scope = socket.assigns.current_scope

    with {:ok, draft, seq} <- DraftSession.persist_now(version_id),
         {:ok, persisted_draft} <- Workflows.get_version(scope, version_id) do
      trigger_impact = compute_trigger_impact(persisted_draft, scope)

      case DraftValidator.validate_for_publish(persisted_draft, scope) do
        :ok ->
          case Workflows.publish_draft(scope, version_id) do
            {:ok, _published} ->
              socket
              |> assign(:draft, draft)
              |> assign(:collab_seq, seq)
              |> clear_validation_errors()
              |> put_flash(:info, "Workflow published")
              |> push_event("workflow:publish_result", %{success: true})
              |> redirect(to: edit_workflow_path(socket))

            {:error, reason} ->
              socket
              |> assign(:draft, draft)
              |> assign(:collab_seq, seq)
              |> push_event("workflow:publish_result", %{
                success: false,
                error: publish_error_message(reason)
              })
          end

        {:error, errors} ->
          socket
          |> assign(:draft, draft)
          |> assign(:collab_seq, seq)
          |> assign(:validation_errors, validation_error_map(errors))
          |> push_event("workflow:publish_result", %{
            success: false,
            validation_errors: Enum.map(errors, &encode_validation_error/1),
            trigger_impact: trigger_impact
          })
      end
    else
      {:error, reason} ->
        handle_publish_persist_error(socket, reason)
    end
  end

  defp run_test(socket) do
    with {:ok, draft, seq} <- DraftSession.persist_now(socket.assigns.draft.id) do
      socket =
        socket
        |> assign(:draft, draft)
        |> assign(:collab_seq, seq)
        |> cancel_existing_execution()

      case Compiler.compile(draft) do
        {:ok, _workflow, _hash} ->
          start_editor_test_run(socket, draft)

        {:error, errors} ->
          push_event(socket, "compilation_errors", %{errors: format_compilation_errors(errors)})
      end
    else
      {:error, reason} ->
        put_flash(socket, :error, "Could not save workflow: #{inspect(reason)}")
    end
  end

  defp start_editor_test_run(socket, %WorkflowDefinitionVersion{} = draft) do
    case Workflows.start_run(
           socket.assigns.current_scope,
           draft,
           %{},
           triggered_by: %{
             "kind" => "editor_test",
             "user_id" => socket.assigns.current_user_id
           }
         ) do
      {:ok, run} ->
        :ok = maybe_subscribe_to_run_topic(run_topic(run.id))

        socket
        |> assign(:step_executions, [])
        |> assign(:run_topic, run_topic(run.id))
        |> assign(:debug_execution_id, run.id)
        |> refresh_execution_state(run.id)
        |> maybe_assign_started_execution(run)

      {:error, reason} ->
        put_flash(socket, :error, "Could not start test run: #{inspect(reason)}")
    end
  end

  defp cancel_execution(%{assigns: %{execution: %{id: run_id}}} = socket)
       when is_binary(run_id) do
    case execution_terminal?(socket.assigns.execution) do
      true ->
        socket

      false ->
        case Workflows.cancel_run(socket.assigns.current_scope, run_id) do
          {:ok, cancelled_run} ->
            assign(socket, :execution, encode_execution(cancelled_run))

          {:error, _reason} ->
            socket
        end
    end
  end

  defp cancel_execution(socket), do: socket

  defp load_step_io(%{assigns: %{execution: %{id: run_id}}} = socket, payload)
       when is_binary(run_id) do
    with {:ok, step_execution_id} <- step_execution_id_from_payload(socket, payload),
         {:ok, step_io} <-
           Workflows.load_run_step_io(socket.assigns.current_scope, run_id, step_execution_id) do
      push_event(socket, "step_io_loaded", step_io)
    else
      _error ->
        case inline_step_io(socket, payload) do
          nil -> socket
          step_io -> push_event(socket, "step_io_loaded", step_io)
        end
    end
  end

  defp load_step_io(socket, _payload), do: socket

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
    case preview_request(payload) do
      {:ok, %{key: key, step_id: step_id, expression: expression}} ->
        case Map.get(socket.assigns.preview_timers, key) do
          nil -> :ok
          timer_ref -> Process.cancel_timer(timer_ref)
        end

        timer_ref = make_ref()

        Process.send_after(
          self(),
          {:preview_expression, key, step_id, expression, timer_ref},
          @preview_debounce_ms
        )

        assign(socket, :preview_timers, Map.put(socket.assigns.preview_timers, key, timer_ref))

      :error ->
        socket
    end
  end

  defp resolve_field_options(socket, payload) do
    with {:ok, resolver, params} <- field_resolver_request(socket.assigns.draft, payload),
         {:ok, options} <-
           resolver.resolve(%{
             q: resolver_query(payload),
             params: params,
             context: resolver_context(socket)
           }) do
      {:ok, maybe_push_credential_results(socket, resolver, payload, options), options}
    else
      {:error, reason} ->
        {:error, maybe_push_credential_results(socket, nil, payload, []), reason}
    end
  end

  defp search_credentials(socket, payload) do
    case CredentialsResolver.resolve(%{
           q: resolver_query(payload),
           params: search_credentials_params(payload),
           context: resolver_context(socket)
         }) do
      {:ok, options} ->
        maybe_push_credential_results(socket, CredentialsResolver, payload, options)

      {:error, reason} ->
        socket
        |> assign(:credential_options, [])
        |> push_event(
          "credential_results",
          Map.merge(credential_result_metadata(payload), %{
            error: encode_reason(reason),
            options: []
          })
        )
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

  defp cancel_existing_execution(%{assigns: %{execution: %{id: run_id}}} = socket)
       when is_binary(run_id) do
    if execution_terminal?(socket.assigns.execution) do
      unsubscribe_from_run(run_id)
      socket
    else
      _ = Workflows.cancel_run(socket.assigns.current_scope, run_id)
      unsubscribe_from_run(run_id)
      socket
    end
  end

  defp cancel_existing_execution(socket), do: socket

  defp refresh_execution_state(socket, run_id) when is_binary(run_id) do
    case load_execution_snapshot(socket.assigns.current_scope, run_id) do
      {:ok, execution, step_executions} ->
        socket
        |> assign(:execution, execution)
        |> assign(:step_executions, step_executions)

      {:error, _reason} ->
        socket
    end
  end

  defp refresh_execution_state(socket, _run_id), do: socket

  defp load_execution_snapshot(scope, run_id) when is_binary(run_id) do
    with {:ok, run} <- Workflows.get_run(scope, run_id),
         {:ok, step_executions} <- Workflows.list_run_step_executions(scope, run_id) do
      {:ok, encode_execution(run), step_executions}
    end
  end

  defp maybe_assign_started_execution(
         %{assigns: %{execution: nil}} = socket,
         %WorkflowRun{} = run
       ) do
    assign(socket, :execution, encode_execution(run))
  end

  defp maybe_assign_started_execution(socket, _run), do: socket

  defp maybe_apply_step_started(socket, run_id, payload) do
    if current_execution_id(socket) == run_id do
      assign(
        socket,
        :step_executions,
        upsert_step_started(socket.assigns.step_executions, socket, payload)
      )
    else
      socket
    end
  end

  defp maybe_apply_step_completed(socket, run_id, payload) do
    if current_execution_id(socket) == run_id do
      assign(
        socket,
        :step_executions,
        upsert_step_completed(socket.assigns.step_executions, socket, payload)
      )
    else
      socket
    end
  end

  defp maybe_apply_step_failed(socket, run_id, payload) do
    if current_execution_id(socket) == run_id do
      assign(
        socket,
        :step_executions,
        upsert_step_failed(socket.assigns.step_executions, socket, payload)
      )
    else
      socket
    end
  end

  defp maybe_apply_run_status(socket, run_id, status, payload) do
    if current_execution_id(socket) == run_id do
      socket =
        socket
        |> refresh_terminal_execution(run_id, status)
        |> update_execution_status(status, payload)
        |> maybe_unsubscribe_terminal_run(run_id, status)

      socket
    else
      socket
    end
  end

  defp refresh_terminal_execution(socket, run_id, status) do
    if terminal_status?(status) do
      refresh_execution_state(socket, run_id)
    else
      socket
    end
  end

  defp update_execution_status(%{assigns: %{execution: execution}} = socket, status, payload)
       when is_map(execution) do
    completed_at =
      if terminal_status?(status) do
        encode_datetime(Map.get(payload, :timestamp) || Map.get(payload, "timestamp"))
      else
        nil
      end

    execution =
      execution
      |> Map.put(:status, encode_execution_status(status))
      |> maybe_put(:completed_at, completed_at)

    assign(socket, :execution, execution)
  end

  defp update_execution_status(socket, _status, _payload), do: socket

  defp maybe_unsubscribe_terminal_run(socket, run_id, status) do
    if terminal_status?(status) do
      unsubscribe_from_run(run_id)
      assign(socket, :run_topic, nil)
    else
      socket
    end
  end

  defp upsert_step_started(step_executions, socket, payload) do
    step_execution =
      base_step_execution(socket, payload)
      |> Map.put(:status, "running")
      |> Map.put(:input_data, payload_value(payload, "input"))
      |> Map.put(:queued_at, encode_datetime(payload_value(payload, "started_at")))
      |> Map.put(:started_at, encode_datetime(payload_value(payload, "started_at")))
      |> Map.put(:inserted_at, encode_datetime(payload_value(payload, "started_at")))
      |> put_step_execution_metadata(%{
        input_fact_hash: payload_value(payload, "input_fact_hash"),
        output_fact_hash: nil,
        output_summary: nil
      })

    put_step_execution(step_executions, step_execution)
  end

  defp upsert_step_completed(step_executions, socket, payload) do
    step_execution =
      socket
      |> base_step_execution(payload)
      |> merge_existing_step_execution(step_executions)
      |> Map.put(:status, "completed")
      |> Map.put(:input_data, existing_or_payload(step_executions, payload, :input_data, "input"))
      |> Map.put(:output_data, payload_value(payload, "output"))
      |> Map.put(:duration_us, payload_value(payload, "duration_us"))
      |> Map.put(:completed_at, encode_datetime(payload_value(payload, "completed_at")))
      |> put_step_execution_metadata(%{
        input_fact_hash: payload_value(payload, "input_fact_hash"),
        output_fact_hash: payload_value(payload, "output_fact_hash"),
        output_summary: payload_value(payload, "output_summary")
      })

    put_step_execution(step_executions, step_execution)
  end

  defp upsert_step_failed(step_executions, socket, payload) do
    step_execution =
      socket
      |> base_step_execution(payload)
      |> merge_existing_step_execution(step_executions)
      |> Map.put(:status, "failed")
      |> Map.put(:input_data, existing_or_payload(step_executions, payload, :input_data, "input"))
      |> Map.put(:error, payload_value(payload, "error"))
      |> Map.put(:duration_us, payload_value(payload, "duration_us"))
      |> Map.put(:completed_at, encode_datetime(payload_value(payload, "failed_at")))
      |> put_step_execution_metadata(%{
        input_fact_hash: payload_value(payload, "input_fact_hash"),
        output_fact_hash: nil,
        output_summary: nil
      })

    put_step_execution(step_executions, step_execution)
  end

  defp base_step_execution(socket, payload) do
    step_id = payload_value(payload, "step_id")
    started_at = encode_datetime(payload_value(payload, "started_at"))
    step_execution_id = step_execution_id(payload)

    %{
      id: step_execution_id,
      execution_id: payload_value(payload, "run_id"),
      step_id: step_id,
      step_type_id: step_type_id(socket.assigns.draft, step_id),
      status: "pending",
      input_data: nil,
      output_data: nil,
      output_item_count: nil,
      item_index: nil,
      items_total: nil,
      error: nil,
      attempt: payload_value(payload, "attempt") || 0,
      retry_of_id: nil,
      duration_us: nil,
      queued_at: started_at,
      started_at: started_at,
      completed_at: nil,
      metadata: %{},
      inserted_at: started_at || encode_datetime(DateTime.utc_now())
    }
  end

  defp merge_existing_step_execution(step_execution, step_executions) do
    case Enum.find(step_executions, &(&1.id == step_execution.id)) do
      nil -> step_execution
      existing -> Map.merge(step_execution, existing)
    end
  end

  defp put_step_execution(step_executions, step_execution) do
    remaining =
      Enum.reject(step_executions, fn existing ->
        existing.id == step_execution.id
      end)

    (remaining ++ [step_execution])
    |> Enum.sort_by(&execution_timestamp/1)
  end

  defp put_step_execution_metadata(step_execution, additions) do
    metadata =
      step_execution
      |> Map.get(:metadata, %{})
      |> Map.merge(Enum.reject(additions, fn {_key, value} -> is_nil(value) end) |> Map.new())

    Map.put(step_execution, :metadata, metadata)
  end

  defp existing_or_payload(step_executions, payload, field, payload_key) do
    case Enum.find(step_executions, &(&1.id == step_execution_id(payload))) do
      nil -> payload_value(payload, payload_key)
      existing -> fetch_value(existing, field) || payload_value(payload, payload_key)
    end
  end

  defp step_execution_id(payload) do
    runnable_id = payload_value(payload, "runnable_id")
    run_id = payload_value(payload, "run_id")
    attempt = payload_value(payload, "attempt") || 0
    "#{run_id}:#{runnable_id}:#{attempt}"
  end

  defp step_type_id(%WorkflowDefinitionVersion{} = draft, step_id) when is_binary(step_id) do
    case Enum.find(draft.steps, &(&1.id == step_id)) do
      %Step{type_id: type_id} -> type_id
      _ -> "unknown"
    end
  end

  defp step_type_id(_draft, _step_id), do: "unknown"

  defp current_execution_id(%{assigns: %{execution: %{id: run_id}}}) when is_binary(run_id),
    do: run_id

  defp current_execution_id(%{assigns: %{debug_execution_id: run_id}}) when is_binary(run_id),
    do: run_id

  defp current_execution_id(_socket), do: nil

  defp execution_terminal?(%{status: status}), do: terminal_status?(status)
  defp execution_terminal?(_execution), do: false

  defp terminal_status?(status) when is_atom(status),
    do: status in [:completed, :failed, :cancelled]

  defp terminal_status?(status) when is_binary(status) do
    status in ["completed", "failed", "cancelled"]
  end

  defp terminal_status?(_status), do: false

  defp unsubscribe_from_run(run_id) when is_binary(run_id) do
    Phoenix.PubSub.unsubscribe(Fizz.PubSub, run_topic(run_id))
  end

  defp unsubscribe_from_run(_run_id), do: :ok

  defp format_compilation_errors(errors) when is_list(errors) do
    Enum.map(errors, fn error ->
      %{
        step_id: Map.get(error, :step_id) || Map.get(error, "step_id"),
        message: Map.get(error, :message) || Map.get(error, "message") || inspect(error)
      }
    end)
  end

  defp format_compilation_errors(_errors), do: []

  defp step_execution_id_from_payload(socket, payload) do
    case payload_value(payload, "step_execution_id") do
      step_execution_id when is_binary(step_execution_id) ->
        {:ok, step_execution_id}

      _ ->
        case payload_value(payload, "step_id") do
          step_id when is_binary(step_id) ->
            socket.assigns.step_executions
            |> Enum.filter(&(fetch_value(&1, :step_id) == step_id))
            |> pick_latest_execution()
            |> case do
              %{id: id} -> {:ok, id}
              _ -> {:error, :step_execution_not_found}
            end

          _ ->
            {:error, :step_execution_not_found}
        end
    end
  end

  defp inline_step_io(socket, payload) do
    with {:ok, step_execution_id} <- step_execution_id_from_payload(socket, payload),
         %{} = step_execution <-
           Enum.find(socket.assigns.step_executions, &(&1.id == step_execution_id)) do
      %{
        step_execution_id: step_execution.id,
        execution_id: fetch_value(step_execution, :execution_id),
        step_id: fetch_value(step_execution, :step_id),
        attempt: fetch_value(step_execution, :attempt),
        input_data: fetch_value(step_execution, :input_data),
        output_data: fetch_value(step_execution, :output_data)
      }
    else
      _ -> nil
    end
  end

  defp assign_draft_state(socket, draft, seq, undo_state) do
    socket
    |> assign(:draft, draft)
    |> assign(:collab_seq, seq)
    |> assign(:undo_state, undo_state)
    |> clear_validation_errors()
    |> maybe_push_undo_state()
  end

  defp clear_validation_errors(socket) do
    assign(socket, :validation_errors, %{})
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
      execution_type: execution_type(run.triggered_by),
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

  defp execution_type(%{} = triggered_by) do
    case Map.get(triggered_by, :kind) || Map.get(triggered_by, "kind") do
      "editor_test" -> "preview"
      :editor_test -> "preview"
      _ -> "production"
    end
  end

  defp execution_type(_triggered_by), do: "production"

  defp trigger_type(%{} = triggered_by) do
    Map.get(triggered_by, :type) ||
      Map.get(triggered_by, "type") ||
      Map.get(triggered_by, :kind) ||
      Map.get(triggered_by, "kind") ||
      "manual"
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

  defp edit_workflow_path(socket) do
    ~p"/projects/#{socket.assigns.project_id}/workflows/#{socket.assigns.definition_id}/edit"
  end

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

  defp preview_request(payload) do
    step_id = Map.get(payload, "step_id") || Map.get(payload, :step_id)
    expression = Map.get(payload, "expression") || Map.get(payload, :expression) || ""

    case preview_key(payload) do
      key when is_binary(step_id) and is_binary(key) ->
        {:ok, %{key: key, step_id: step_id, expression: expression}}

      _ ->
        :error
    end
  end

  defp build_preview_context(step_id, draft, editor_state, step_executions) do
    %{
      "steps" => build_preview_steps_context(step_id, draft, editor_state, step_executions),
      "input" => build_preview_input_context(step_id, draft, editor_state, step_executions),
      "env" => %{}
    }
  end

  defp build_preview_steps_context(
         step_id,
         %WorkflowDefinitionVersion{} = draft,
         editor_state,
         step_executions
       ) do
    draft
    |> upstream_step_ids(step_id)
    |> Enum.reduce(%{}, fn upstream_step_id, acc ->
      Map.put(
        acc,
        upstream_step_id,
        preview_output_for_step(upstream_step_id, editor_state, step_executions)
      )
    end)
  end

  defp build_preview_steps_context(_step_id, _draft, _editor_state, _step_executions), do: %{}

  defp build_preview_input_context(
         step_id,
         %WorkflowDefinitionVersion{} = draft,
         editor_state,
         step_executions
       ) do
    step_order = step_order_by_id(draft)

    grouped_inputs =
      draft
      |> incoming_connections(step_id)
      |> Enum.sort_by(&Map.get(step_order, &1.source_step_id, map_size(step_order)))
      |> Enum.reduce(%{}, fn connection, acc ->
        target_input =
          case connection.target_input do
            target_input when is_binary(target_input) and target_input != "" -> target_input
            _ -> "main"
          end

        value = preview_output_for_step(connection.source_step_id, editor_state, step_executions)
        Map.update(acc, target_input, [value], &(&1 ++ [value]))
      end)

    collapse_preview_input(grouped_inputs)
  end

  defp build_preview_input_context(_step_id, _draft, _editor_state, _step_executions), do: %{}

  defp collapse_preview_input(grouped_inputs) do
    case Map.keys(grouped_inputs) do
      [] ->
        %{}

      ["main"] ->
        collapse_preview_values(Map.fetch!(grouped_inputs, "main"))

      _keys ->
        Map.new(grouped_inputs, fn {key, values} -> {key, collapse_preview_values(values)} end)
    end
  end

  defp collapse_preview_values([value]), do: value
  defp collapse_preview_values(values), do: values

  defp preview_output_for_step(step_id, editor_state, step_executions) do
    case Map.fetch(editor_state.pinned_outputs, step_id) do
      {:ok, pinned_output} ->
        pinned_output

      :error ->
        case latest_step_output(step_executions, step_id) do
          {:ok, output_data} -> output_data
          :error -> %{}
        end
    end
  end

  defp latest_step_output(step_executions, step_id) do
    executions =
      Enum.filter(step_executions, fn step_execution ->
        fetch_value(step_execution, :step_id) == step_id
      end)

    latest_execution =
      executions
      |> Enum.filter(&single_item_execution?/1)
      |> pick_latest_execution()
      |> case do
        nil -> pick_latest_execution(executions)
        execution -> execution
      end

    case latest_execution do
      nil -> :error
      execution -> {:ok, fetch_value(execution, :output_data)}
    end
  end

  defp single_item_execution?(step_execution) do
    case fetch_value(step_execution, :item_index) do
      nil -> true
      _ -> false
    end
  end

  defp pick_latest_execution([]), do: nil

  defp pick_latest_execution(step_executions) do
    Enum.reduce(step_executions, nil, fn step_execution, latest ->
      case latest do
        nil ->
          step_execution

        latest ->
          if execution_timestamp(step_execution) >= execution_timestamp(latest) do
            step_execution
          else
            latest
          end
      end
    end)
  end

  defp execution_timestamp(step_execution) do
    [
      fetch_value(step_execution, :completed_at),
      fetch_value(step_execution, :started_at),
      fetch_value(step_execution, :inserted_at)
    ]
    |> Enum.map(&timestamp_for/1)
    |> Enum.max(fn -> 0 end)
  end

  defp timestamp_for(nil), do: 0
  defp timestamp_for(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp timestamp_for(%NaiveDateTime{} = value), do: NaiveDateTime.to_gregorian_seconds(value)
  defp timestamp_for(value) when is_integer(value), do: value

  defp timestamp_for(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> DateTime.to_unix(parsed, :microsecond)
      _ -> 0
    end
  end

  defp timestamp_for(_value), do: 0

  defp incoming_connections(%WorkflowDefinitionVersion{} = draft, step_id) do
    Enum.filter(draft.connections, &(&1.target_step_id == step_id))
  end

  defp step_order_by_id(%WorkflowDefinitionVersion{} = draft) do
    draft.steps
    |> Enum.with_index()
    |> Map.new(fn {%Step{id: step_id}, index} -> {step_id, index} end)
  end

  defp upstream_step_ids(%WorkflowDefinitionVersion{} = draft, step_id) do
    direct_parents =
      Enum.reduce(draft.connections, %{}, fn connection, acc ->
        Map.update(acc, connection.target_step_id, [connection.source_step_id], fn parent_ids ->
          if connection.source_step_id in parent_ids do
            parent_ids
          else
            parent_ids ++ [connection.source_step_id]
          end
        end)
      end)

    step_order = step_order_by_id(draft)

    step_id
    |> do_upstream_step_ids(direct_parents, MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort_by(&Map.get(step_order, &1, map_size(step_order)))
  end

  defp do_upstream_step_ids(step_id, direct_parents, visited) do
    direct_parents
    |> Map.get(step_id, [])
    |> Enum.reduce(visited, fn parent_step_id, acc ->
      case MapSet.member?(acc, parent_step_id) do
        true ->
          acc

        false ->
          updated_visited = MapSet.put(acc, parent_step_id)
          do_upstream_step_ids(parent_step_id, direct_parents, updated_visited)
      end
    end)
  end

  defp workflow_preview_context(%WorkflowDefinition{} = definition) do
    %{"id" => definition.id, "name" => definition.name}
  end

  defp workflow_preview_context(_definition), do: %{}

  defp field_resolver_request(%WorkflowDefinitionVersion{} = draft, payload) do
    with {:ok, step_id} <- resolver_step_id(payload),
         {:ok, field_key} <- resolver_field_key(payload),
         {:ok, step} <- fetch_step(draft, step_id),
         {:ok, type} <- Steps.get_type(step.type_id),
         {:ok, field_schema} <- fetch_config_field_schema(type, field_key),
         {:ok, resolver} <- fetch_field_resolver(field_schema) do
      {:ok, resolver, merge_resolver_params(field_schema, payload)}
    end
  end

  defp field_resolver_request(_draft, _payload), do: {:error, :draft_not_loaded}

  defp resolver_step_id(payload) do
    case Map.get(payload, "node_id") || Map.get(payload, :node_id) ||
           Map.get(payload, "step_id") || Map.get(payload, :step_id) do
      step_id when is_binary(step_id) -> {:ok, step_id}
      _ -> {:error, :step_id_required}
    end
  end

  defp resolver_field_key(payload) do
    case Map.get(payload, "field_key") || Map.get(payload, :field_key) do
      field_key when is_binary(field_key) -> {:ok, field_key}
      _ -> {:error, :field_key_required}
    end
  end

  defp fetch_step(%WorkflowDefinitionVersion{} = draft, step_id) do
    case Enum.find(draft.steps, &(&1.id == step_id)) do
      %Step{} = step -> {:ok, step}
      nil -> {:error, :step_not_found}
    end
  end

  defp fetch_config_field_schema(%Type{} = type, field_key) do
    case get_in(type.config_schema, ["properties", field_key]) do
      field_schema when is_map(field_schema) -> {:ok, field_schema}
      _ -> {:error, :field_not_found}
    end
  end

  defp fetch_field_resolver(field_schema) do
    case get_in(field_schema, ["ui", "resolver"]) do
      resolver when is_atom(resolver) ->
        case Code.ensure_loaded(resolver) do
          {:module, _module} ->
            case function_exported?(resolver, :resolve, 1) do
              true -> {:ok, resolver}
              false -> {:error, :resolver_not_found}
            end

          _ ->
            {:error, :resolver_not_found}
        end

      _ ->
        {:error, :resolver_not_found}
    end
  end

  defp merge_resolver_params(field_schema, payload) do
    schema_resolver_params(field_schema)
    |> Map.merge(payload_resolver_params(payload))
  end

  defp schema_resolver_params(field_schema) do
    case get_in(field_schema, ["ui", "params"]) do
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp payload_resolver_params(payload) do
    params =
      case Map.get(payload, "params") || Map.get(payload, :params) do
        params when is_map(params) -> params
        _ -> %{}
      end

    params
    |> maybe_put(
      "provider_filter",
      Map.get(payload, "provider_filter") || Map.get(payload, :provider_filter)
    )
    |> maybe_put("auth_types", Map.get(payload, "auth_types") || Map.get(payload, :auth_types))
    |> maybe_put("provider", Map.get(payload, "provider") || Map.get(payload, :provider))
    |> maybe_put("auth_type", Map.get(payload, "auth_type") || Map.get(payload, :auth_type))
  end

  defp search_credentials_params(payload) do
    case payload_resolver_params(payload) do
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp resolver_query(payload) do
    case Map.get(payload, "q") || Map.get(payload, :q) do
      query when is_binary(query) -> query
      _ -> ""
    end
  end

  defp resolver_context(socket) do
    %{current_scope: socket.assigns.current_scope}
  end

  defp maybe_push_credential_results(socket, CredentialsResolver, payload, options) do
    socket
    |> assign(:credential_options, options)
    |> push_event(
      "credential_results",
      Map.merge(credential_result_metadata(payload), %{options: options})
    )
  end

  defp maybe_push_credential_results(socket, _resolver, _payload, _options), do: socket

  defp credential_result_metadata(payload) do
    %{}
    |> maybe_put(:node_id, Map.get(payload, "node_id") || Map.get(payload, :node_id))
    |> maybe_put(:step_id, Map.get(payload, "step_id") || Map.get(payload, :step_id))
    |> maybe_put(:field_key, Map.get(payload, "field_key") || Map.get(payload, :field_key))
    |> maybe_put(:q, Map.get(payload, "q") || Map.get(payload, :q))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp preview_expression_value(expression, context) do
    case Expressions.preview(expression, context) do
      {:ok, preview_result} ->
        preview_result

      {:error, "Parse error: " <> message} ->
        %{
          type: "parse_error",
          message: message,
          errors: [message],
          text: expression
        }

      {:error, "Render error: " <> message} ->
        %{
          type: "render_error",
          message: message,
          text: expression
        }

      {:error, message} ->
        %{
          type: "render_error",
          message: message,
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

  defp encode_validation_error(%DraftValidator.ValidationError{} = error) do
    %{
      step_id: error.step_id,
      field: error.field,
      message: error.message,
      severity: Atom.to_string(error.severity),
      code: Atom.to_string(error.code)
    }
  end

  defp validation_error_map(errors) do
    errors
    |> Enum.reject(&is_nil(&1.step_id))
    |> Enum.group_by(& &1.step_id, & &1)
  end

  defp handle_publish_persist_error(socket, %Ecto.Changeset{} = changeset) do
    draft = socket.assigns.draft
    scope = socket.assigns.current_scope
    trigger_impact = compute_trigger_impact(draft, scope)

    case DraftValidator.validate_for_publish(draft, scope) do
      {:error, errors} ->
        socket
        |> assign(:validation_errors, validation_error_map(errors))
        |> push_event("workflow:publish_result", %{
          success: false,
          validation_errors: Enum.map(errors, &encode_validation_error/1),
          trigger_impact: trigger_impact
        })

      :ok ->
        push_event(socket, "workflow:publish_result", %{
          success: false,
          error: publish_error_message(changeset)
        })
    end
  end

  defp handle_publish_persist_error(socket, reason) do
    push_event(socket, "workflow:publish_result", %{
      success: false,
      error: publish_error_message(reason)
    })
  end

  defp publish_error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_changeset_error/1)
    |> collect_changeset_messages()
    |> List.first()
    |> case do
      nil -> "Publish failed"
      message -> message
    end
  end

  defp publish_error_message(reason), do: encode_reason(reason)

  defp translate_changeset_error({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp collect_changeset_messages(errors) when is_map(errors) do
    errors
    |> Enum.flat_map(fn {_field, value} -> collect_changeset_messages(value) end)
  end

  defp collect_changeset_messages(errors) when is_list(errors) do
    Enum.flat_map(errors, fn
      value when is_binary(value) ->
        [value]

      value when is_list(value) or is_map(value) ->
        collect_changeset_messages(value)

      _value ->
        []
    end)
  end

  defp collect_changeset_messages(_errors), do: []

  defp compute_trigger_impact(%WorkflowDefinitionVersion{} = draft, scope) do
    case Compiler.compile(draft) do
      {:ok, workflow, _hash} ->
        with {:ok, registrations} <-
               Triggers.list_registrations(scope,
                 definition_id: draft.workflow_definition_id,
                 status: :active
               ),
             {:ok, desired_registrations} <-
               desired_trigger_registrations(
                 Map.get(workflow.fizz_metadata, :trigger_manifest, []),
                 draft,
                 scope
               ) do
          compare_trigger_registrations(
            desired_registrations,
            Enum.filter(registrations, &is_nil(&1.run_id))
          )
        else
          {:error, _reason} -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp desired_trigger_registrations(trigger_manifest, draft, scope)
       when is_list(trigger_manifest) do
    context = trigger_sync_context(draft, scope)

    Enum.reduce_while(trigger_manifest, {:ok, []}, fn trigger, {:ok, acc} ->
      with {:ok, executor} <- StepExecutorBehaviour.resolve(trigger.type_id),
           {:ok, spec} <- executor.registration_spec(trigger.config, context) do
        {:cont,
         {:ok,
          [
            %{
              step_id: trigger.step_id,
              type_id: trigger.type_id,
              kind: Atom.to_string(spec.kind),
              config_digest: trigger_registration_digest(spec)
            }
            | acc
          ]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, registrations} ->
        {:ok, Enum.sort_by(registrations, & &1.step_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp trigger_sync_context(draft, scope) do
    %{
      workflow_definition_id: draft.workflow_definition_id,
      definition_version_id: draft.id,
      project_id: socket_project_id(scope),
      workos_organization_id: socket_organization_id(scope)
    }
  end

  defp socket_project_id(%{project: %{id: project_id}}), do: project_id
  defp socket_project_id(_scope), do: nil

  defp socket_organization_id(%{project: %{workos_organization_id: organization_id}}),
    do: organization_id

  defp socket_organization_id(%{organization_id: organization_id}), do: organization_id
  defp socket_organization_id(_scope), do: nil

  defp trigger_registration_digest(spec) do
    %{
      "kind" => spec.kind,
      "params" => spec.params,
      "dedup_key" => spec.dedup_key
    }
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp compare_trigger_registrations(desired_registrations, current_registrations) do
    current_by_step_id = Map.new(current_registrations, &{&1.step_id, &1})
    desired_by_step_id = Map.new(desired_registrations, &{&1.step_id, &1})

    added =
      desired_registrations
      |> Enum.reject(&Map.has_key?(current_by_step_id, &1.step_id))
      |> Enum.sort_by(& &1.step_id)

    updated =
      desired_registrations
      |> Enum.filter(fn desired ->
        case Map.get(current_by_step_id, desired.step_id) do
          nil ->
            false

          current ->
            current.kind != desired.kind or current.config_digest != desired.config_digest
        end
      end)
      |> Enum.sort_by(& &1.step_id)

    removed =
      current_registrations
      |> Enum.reject(&Map.has_key?(desired_by_step_id, &1.step_id))
      |> Enum.map(fn registration ->
        %{
          step_id: registration.step_id,
          kind: registration.kind
        }
      end)
      |> Enum.sort_by(& &1.step_id)

    %{
      added: added,
      updated: updated,
      removed: removed,
      unchanged_count: max(length(desired_registrations) - length(added) - length(updated), 0)
    }
  end

  defp has_payload_key?(payload, string_key, atom_key) do
    Map.has_key?(payload, string_key) or Map.has_key?(payload, atom_key)
  end

  defp fetch_value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_value(_map, _key), do: nil
end
