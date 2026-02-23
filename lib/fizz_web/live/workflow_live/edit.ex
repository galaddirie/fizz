defmodule FizzWeb.WorkflowLive.Edit do
  @moduledoc """
  LiveView for designing and editing workflows with real-time collaboration.
  """
  use FizzWeb, :live_view

  alias Fizz.Accounts
  alias Fizz.Workflows
  alias Fizz.Integrations
  alias Fizz.Repo
  alias Fizz.Steps
  alias Fizz.Steps.Registry, as: StepRegistry
  alias Fizz.Collaboration.EditorState
  alias Fizz.Collaboration.EditSession.{Server, Presence, PubSub, Operations}
  alias Fizz.Executions
  alias Fizz.Executions.Execution
  alias Fizz.Executions.PubSub, as: ExecutionPubSub
  alias Fizz.Runtime.Execution.Supervisor, as: ExecutionSupervisor
  alias FizzWeb.WorkflowLive.Edit.Command
  alias FizzWeb.WorkflowLive.Edit.ExpressionPreview
  alias FizzWeb.WorkflowLive.Edit.PresenceFormatter
  alias FizzWeb.WorkflowLive.Edit.EditStepProjection
  alias FizzWeb.WorkflowLive.Paths
  alias Ecto.UUID
  require Logger

  @execution_lifecycle_events [
    :execution_started,
    :execution_updated,
    :execution_completed,
    :execution_cancelled,
    :execution_failed
  ]
  @step_lifecycle_events [
    :step_started,
    :step_completed,
    :step_failed,
    :step_skipped,
    :step_cancelled
  ]

  @impl true
  def mount(%{"workspace_id" => workspace_id, "id" => id} = params, _session, socket) do
    debug_execution_id = normalize_debug_execution_id(params)

    case Accounts.build_scope_for_workspace(socket.assigns.current_scope, workspace_id) do
      {:ok, scope} ->
        user = scope.user

        case Workflows.get_workflow_with_draft(scope, id) do
          {:ok, workflow} ->
            case PubSub.authorize_edit(scope, workflow.id) do
              :ok ->
                step_types = Steps.list_types()
                node_library_items = Steps.list_library_items()

                socket =
                  socket
                  |> assign(:current_scope, scope)
                  |> assign(:page_title, "Editing #{workflow.name}")
                  |> assign(:workflow, workflow)
                  |> assign(:step_types, step_types)
                  |> assign(:node_library_items, node_library_items)
                  |> assign(:editor_state, %EditorState{workflow_id: workflow.id})
                  |> assign(:presences, [])
                  |> assign(:current_user_id, user.id)
                  |> assign(:execution, nil)
                  |> assign(:step_executions, [])
                  |> assign(:execution_id, nil)
                  |> assign(:expression_previews, %{})
                  |> assign(:webhook_execution_subscribed, false)
                  |> assign(:undo_state, nil)
                  |> assign(:debug_execution_id, nil)

                # Only set up collaboration when WebSocket is connected
                socket =
                  if connected?(socket) do
                    case setup_collaboration(socket, workflow.id, user) do
                      {:ok, collaboration_socket} ->
                        maybe_load_debug_execution(collaboration_socket, debug_execution_id)

                      {:error, collaboration_socket} ->
                        collaboration_socket
                    end
                  else
                    socket
                  end

                {:ok, socket, layout: false}

              {:error, :unauthorized} ->
                {:ok,
                 socket
                 |> assign(:current_scope, scope)
                 |> put_flash(:error, "You do not have permission to edit this workflow")
                 |> redirect(to: Paths.workflow_show_path(scope, workflow.id))}
            end

          {:error, :not_found} ->
            {:ok,
             socket
             |> assign(:current_scope, scope)
             |> put_flash(:error, "Workflow not found")
             |> redirect(to: Paths.workflows_index_path(scope))}
        end

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Workspace not found")
         |> redirect(to: ~p"/workspaces")}
    end
  end

  # =============================================================================
  # Collaboration Setup
  # =============================================================================

  defp setup_collaboration(socket, workflow_id, user) do
    # Ensure edit session server is running
    case Fizz.Collaboration.EditSession.Supervisor.ensure_session(
           socket.assigns.current_scope,
           workflow_id
         ) do
      {:ok, _pid} ->
        {:ok, do_setup_collaboration(socket, workflow_id, user)}

      {:error, reason} ->
        Logger.error("Failed to start edit session",
          workflow_id: workflow_id,
          reason: inspect(reason)
        )

        {:error,
         socket
         |> put_flash(:error, "Unable to start collaborative editing session")
         |> redirect(to: Paths.workflow_show_path(socket.assigns.current_scope, workflow_id))}
    end
  end

  defp do_setup_collaboration(socket, workflow_id, user) do
    # Subscribe to operation broadcasts
    :ok = Phoenix.PubSub.subscribe(Fizz.PubSub, PubSub.session_topic(workflow_id))

    # Subscribe to presence topic for diffs
    :ok = Phoenix.PubSub.subscribe(Fizz.PubSub, Presence.topic(workflow_id))

    # Track this user's presence
    {:ok, _} = Presence.track_user(workflow_id, user, socket)

    # Get initial editor state
    editor_state =
      case Server.get_editor_state(workflow_id) do
        {:ok, state} -> state
        _ -> %EditorState{workflow_id: workflow_id}
      end

    # Get initial presence list
    presences = PresenceFormatter.format(Presence.list_users(workflow_id))

    {draft, editor_state} =
      case Server.get_sync_state(workflow_id) do
        {:ok, %{type: :full_sync, draft: draft, editor_state: sync_editor_state}} ->
          {draft, deserialize_editor_state(sync_editor_state, workflow_id)}

        _ ->
          {socket.assigns.workflow.draft, editor_state}
      end

    # Get latest execution
    {execution, step_executions} =
      case Executions.list_workflow_executions(
             socket.assigns.current_scope,
             socket.assigns.workflow,
             limit: 1
           ) do
        [latest] ->
          {:ok, full_execution} =
            Executions.get_execution_with_steps(socket.assigns.current_scope, latest.id)

          {full_execution, full_execution.step_executions}

        [] ->
          {nil, []}
      end

    socket =
      socket
      |> assign(:workflow, %{socket.assigns.workflow | draft: draft})
      |> assign(:editor_state, editor_state)
      |> assign(:presences, presences)
      |> assign(:execution, execution)
      |> assign(:execution_id, if(execution, do: execution.id, else: nil))
      |> assign(:step_executions, step_executions)
      |> assign(:undo_state, fetch_undo_state(workflow_id, user.id))
      |> maybe_toggle_webhook_subscription(editor_state)

    push_undo_state(socket)
  end

  defp normalize_debug_execution_id(params) when is_map(params) do
    case Map.get(params, "debug_execution_id") do
      nil -> nil
      "" -> nil
      id -> id
    end
  end

  defp normalize_debug_execution_id(_params), do: nil

  defp maybe_load_debug_execution(socket, nil), do: socket

  defp maybe_load_debug_execution(socket, debug_execution_id) do
    case Executions.get_execution_with_steps(socket.assigns.current_scope, debug_execution_id) do
      {:ok, execution} ->
        if execution.workflow_id == socket.assigns.workflow.id do
          _ = subscribe_execution(socket.assigns.current_scope, execution.id)

          socket
          |> assign(:execution, execution)
          |> assign(:execution_id, execution.id)
          |> assign(:step_executions, execution.step_executions || [])
          |> assign(:debug_execution_id, execution.id)
        else
          socket
          |> assign(:debug_execution_id, nil)
          |> put_flash(:error, "Debug execution does not belong to this workflow")
        end

      {:error, :not_found} ->
        socket
        |> assign(:debug_execution_id, nil)
        |> put_flash(:error, "Debug execution not found")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} hide_nav={true} full_bleed={true}>
      <div class="h-screen w-full overflow-hidden bg-base-200">
        <.vue
          v-component="WorkflowEditor"
          v-ssr={false}
          v-socket={@socket}
          workflow={@workflow}
          stepTypes={@step_types}
          nodeLibraryItems={@node_library_items}
          editorState={@editor_state}
          presences={@presences}
          currentUserId={@current_user_id}
          execution={@execution}
          stepExecutions={@step_executions}
          undoState={@undo_state}
          v-on:editor_command={JS.push("editor_command")}
          expressionPreviews={@expression_previews}
          debugExecutionId={@debug_execution_id}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("editor_command", params, socket) do
    with {:ok, command, payload} <- Command.parse(params),
         true <- Command.valid?(command) do
      handle_event(command, payload, socket)
    else
      false ->
        Logger.debug("Ignoring unsupported workflow editor command",
          command: Map.get(params, "type")
        )

        {:noreply, socket}

      {:error, :invalid} ->
        Logger.debug("Ignoring invalid workflow editor command payload", payload: inspect(params))
        {:noreply, socket}
    end
  end

  # =============================================================================
  # Step Operations
  # =============================================================================

  @impl true
  def handle_event("add_step", %{"type_id" => type_id, "position" => pos} = params, socket) do
    step_type_name =
      case StepRegistry.get(type_id) do
        {:ok, type} -> type.name
        _ -> "Step"
      end

    steps = socket.assigns.workflow.draft.steps || []
    {unique_name, step_id} = Fizz.Workflows.generate_unique_step_identity(steps, step_type_name)

    step = %{
      id: step_id,
      type_id: type_id,
      name: unique_name,
      config: StepRegistry.get_default_config(type_id),
      position: pos,
      notes: nil
    }

    payload =
      case Map.get(params, "group_id") do
        nil -> %{step: step}
        group_id -> %{step: step, group_id: group_id}
      end

    apply_operation(socket, :add_step, payload)
  end

  @impl true
  def handle_event("duplicate_steps", %{"step_ids" => step_ids} = params, socket) do
    step_ids = step_ids |> List.wrap() |> Enum.uniq()

    draft = socket.assigns.workflow.draft
    steps = if(draft, do: draft.steps || [], else: [])
    connections = if(draft, do: draft.connections || [], else: [])
    groups = if(draft, do: draft.groups || [], else: [])

    if step_ids == [] or steps == [] do
      {:noreply, socket}
    else
      position_by_step_id = Map.get(params, "position_by_step_id", %{})

      incoming_group_map =
        case Map.get(params, "group_id_by_step_id") do
          %{} = map -> map
          _ -> %{}
        end

      group_lookup = build_group_lookup(groups)
      group_id_by_step_id = Map.merge(group_lookup, incoming_group_map)

      {new_steps, id_map, group_id_by_new_step_id} =
        build_duplicate_steps(steps, step_ids, position_by_step_id, group_id_by_step_id)

      new_connections = build_duplicate_connections(connections, step_ids, id_map)

      undo_group_id = UUID.generate()

      undo_label =
        "Duplicate #{length(new_steps)} Step#{if(length(new_steps) == 1, do: "", else: "s")}"

      operations =
        Enum.map(new_steps, fn step ->
          step_id = fetch_field(step, :id)

          payload =
            case Map.get(group_id_by_new_step_id, step_id) do
              nil -> %{step: step}
              group_id -> %{step: step, group_id: group_id}
            end

          {:add_step, payload, %{undo_group_id: undo_group_id, undo_label: undo_label}}
        end) ++
          Enum.map(new_connections, fn connection ->
            {:add_connection, %{connection: connection},
             %{undo_group_id: undo_group_id, undo_label: undo_label}}
          end)

      case apply_operations(socket, operations) do
        :ok ->
          new_step_ids = Enum.map(new_steps, &fetch_field(&1, :id))

          socket =
            socket
            |> push_event("workflow:duplicate_selection", %{step_ids: new_step_ids})
            |> push_undo_state()

          {:noreply, socket}

        {:error, reason} ->
          Logger.warning("duplicate_steps failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Unable to duplicate steps")}
      end
    end
  end

  @impl true
  def handle_event("move_step", %{"step_id" => step_id, "position" => pos}, socket) do
    apply_operation(socket, :update_step_position, %{step_id: step_id, position: pos})
  end

  @impl true
  def handle_event("tidy_layout", params, socket) do
    steps = params |> Map.get("steps", []) |> List.wrap()
    groups = params |> Map.get("groups", []) |> List.wrap()
    label = Map.get(params, "label") || "Tidy Workflow"
    undo_group_id = UUID.generate()

    group_ops =
      Enum.map(groups, fn group ->
        group_id = fetch_payload_value(group, :group_id)
        position = normalize_group_position(fetch_payload_value(group, :position) || %{})

        {:update_group, %{group_id: group_id, changes: %{position: position}},
         %{undo_group_id: undo_group_id, undo_label: label}}
      end)

    step_ops =
      Enum.map(steps, fn step ->
        step_id = fetch_payload_value(step, :step_id)
        position = normalize_position(fetch_payload_value(step, :position) || %{})

        {:update_step_position, %{step_id: step_id, position: position},
         %{undo_group_id: undo_group_id, undo_label: label}}
      end)

    case apply_operations(socket, group_ops ++ step_ops) do
      :ok ->
        {:noreply, push_undo_state(socket)}

      {:error, reason} ->
        Logger.warning("tidy_layout failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Unable to tidy layout")}
    end
  end

  @impl true
  def handle_event("update_step", %{"step_id" => step_id, "changes" => changes}, socket) do
    apply_operation(socket, :update_step_metadata, %{step_id: step_id, changes: changes})
  end

  @impl true
  def handle_event("remove_step", %{"step_id" => step_id}, socket) do
    Logger.info("Received remove_step event for step: #{step_id}")
    apply_operation(socket, :remove_step, %{step_id: step_id})
  end

  @impl true
  def handle_event("add_group", params, socket) do
    step_ids =
      params
      |> Map.get("step_ids", [])
      |> List.wrap()
      |> Enum.uniq()

    if step_ids == [] do
      {:noreply, socket}
    else
      group = %{
        id: UUID.generate(),
        name: Map.get(params, "name", "Group"),
        step_ids: step_ids,
        position: normalize_group_position(Map.get(params, "position", %{})),
        color: Map.get(params, "color"),
        collapsed: Map.get(params, "collapsed", false)
      }

      step_positions =
        case Map.get(params, "step_positions") do
          %{} = positions -> positions
          _ -> %{}
        end

      apply_operation(socket, :add_group, %{group: group, step_positions: step_positions})
    end
  end

  @impl true
  def handle_event("update_group", %{"group_id" => group_id} = params, socket) do
    changes =
      params
      |> Map.get("changes", %{})
      |> normalize_group_changes()

    apply_operation(socket, :update_group, %{group_id: group_id, changes: changes})
  end

  @impl true
  def handle_event("remove_group", %{"group_id" => group_id}, socket) do
    apply_operation(socket, :remove_group, %{group_id: group_id})
  end

  @impl true
  def handle_event("set_group_membership", params, socket) do
    group_id =
      case Map.get(params, "group_id") do
        "" -> nil
        group_id -> group_id
      end

    step_ids =
      params
      |> Map.get("step_ids", [])
      |> List.wrap()
      |> Enum.uniq()

    step_positions =
      case Map.get(params, "step_positions") do
        %{} = positions -> positions
        _ -> %{}
      end

    if step_ids == [] do
      {:noreply, socket}
    else
      apply_operation(socket, :set_group_membership, %{
        group_id: group_id,
        step_ids: step_ids,
        step_positions: step_positions
      })
    end
  end

  @impl true
  def handle_event("add_connection", params, socket) do
    connection = %{
      id: UUID.generate(),
      source_step_id: params["source_step_id"],
      target_step_id: params["target_step_id"],
      source_output: params["source_output"] || "main",
      target_input: params["target_input"] || "main"
    }

    apply_operation(socket, :add_connection, %{connection: connection})
  end

  @impl true
  def handle_event("remove_connection", %{"connection_id" => id}, socket) do
    Logger.info("Received remove_connection event for connection: #{id}")
    apply_operation(socket, :remove_connection, %{connection_id: id})
  end

  @impl true
  def handle_event("undo", %{"count" => count}, socket) do
    count = parse_count(count)

    case Server.undo(socket.assigns.workflow.id, socket.assigns.current_user_id, count) do
      {:ok, result} ->
        socket =
          socket
          |> push_event("workflow:undo_applied", %{success: true, label: result.label})
          |> push_undo_state()

        {:noreply, socket}

      {:error, {:conflict, reason, label}} ->
        socket =
          socket
          |> push_event("workflow:undo_conflict", %{reason: inspect(reason), label: label})
          |> push_undo_state()

        {:noreply, socket}

      {:error, _reason} ->
        socket = push_undo_state(socket)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("redo", %{"count" => count}, socket) do
    count = parse_count(count)

    case Server.redo(socket.assigns.workflow.id, socket.assigns.current_user_id, count) do
      {:ok, result} ->
        socket =
          socket
          |> push_event("workflow:redo_applied", %{success: true, label: result.label})
          |> push_undo_state()

        {:noreply, socket}

      {:error, {:conflict, reason, label}} ->
        socket =
          socket
          |> push_event("workflow:redo_conflict", %{reason: inspect(reason), label: label})
          |> push_undo_state()

        {:noreply, socket}

      {:error, _reason} ->
        socket = push_undo_state(socket)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("navigate_revisions", _params, socket) do
    scope = socket.assigns.current_scope
    workflow = socket.assigns.workflow
    {:noreply, push_navigate(socket, to: Paths.workflow_revisions_path(scope, workflow.id))}
  end

  # =============================================================================
  # Editor State Operations
  # =============================================================================

  @impl true
  def handle_event("pin_output", params, socket) do
    step_id = fetch_payload_value(params, :step_id)

    if is_nil(step_id) do
      {:noreply, socket}
    else
      output_data_present? = payload_has_key?(params, :output_data)
      item_index = parse_item_index(params)

      output_data =
        if output_data_present? do
          fetch_payload_value(params, :output_data)
        else
          resolve_pin_output(socket.assigns.step_executions, step_id, item_index)
        end

      if !output_data_present? and is_nil(output_data) do
        {:noreply, put_flash(socket, :error, "No output data available to pin yet")}
      else
        apply_operation(socket, :pin_step_output, %{step_id: step_id, output_data: output_data})
      end
    end
  end

  @impl true
  def handle_event("unpin_output", %{"step_id" => step_id}, socket) do
    apply_operation(socket, :unpin_step_output, %{step_id: step_id})
  end

  @impl true
  def handle_event("disable_step", %{"step_id" => step_id, "mode" => mode}, socket) do
    mode_atom = if mode == "exclude", do: :exclude, else: :skip
    apply_operation(socket, :disable_step, %{step_id: step_id, mode: mode_atom})
  end

  @impl true
  def handle_event("enable_step", %{"step_id" => step_id}, socket) do
    apply_operation(socket, :enable_step, %{step_id: step_id})
  end

  # =============================================================================
  # Presence/Collaboration Events
  # =============================================================================

  @impl true
  def handle_event("mouse_move", params, socket) do
    x = params["x"]
    y = params["y"]
    dragging_steps = params["dragging_steps"]

    Presence.update_interaction(
      socket.assigns.workflow.id,
      socket.assigns.current_user_id,
      if(x && y, do: %{x: x, y: y}, else: nil),
      dragging_steps
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("selection_changed", %{"step_ids" => step_ids}, socket) do
    Presence.update_selection(
      socket.assigns.workflow.id,
      socket.assigns.current_user_id,
      step_ids
    )

    {:noreply, socket}
  end

  # =============================================================================
  # Workflow Operations
  # =============================================================================

  @impl true
  def handle_event("save_workflow", _params, socket) do
    case Server.persist_sync(socket.assigns.workflow.id) do
      :ok ->
        socket = refresh_workflow(socket)
        {:noreply, put_flash(socket, :info, "Workflow draft saved")}

      :noop ->
        {:noreply, put_flash(socket, :info, "No draft changes to save")}

      {:error, reason} ->
        Logger.error("Failed to persist workflow draft: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to save workflow draft")}
    end
  end

  @impl true
  def handle_event("publish_workflow", %{"version_tag" => version_tag} = params, socket) do
    workflow = socket.assigns.workflow
    scope = socket.assigns.current_scope
    changelog = Map.get(params, "changelog", "")

    # First, persist any unsaved draft changes
    _ = Server.persist_sync(workflow.id)

    version_attrs = %{
      version_tag: version_tag,
      changelog: changelog
    }

    case Workflows.publish_workflow(scope, workflow, version_attrs) do
      {:ok, {updated_workflow, _version}} ->
        socket =
          socket
          |> assign(:workflow, Repo.preload(updated_workflow, :draft, force: true))
          |> push_event("workflow:publish_result", %{success: true})
          |> put_flash(:info, "Workflow published as version #{version_tag}")

        {:noreply, socket}

      {:error, {:invalid_workflow, errors}} ->
        error_msg = format_validation_errors(errors)

        socket =
          socket
          |> push_event("workflow:publish_result", %{success: false, error: error_msg})

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to publish workflow: #{inspect(reason)}")
        error_msg = format_publish_error(reason)

        socket =
          socket
          |> push_event("workflow:publish_result", %{success: false, error: error_msg})

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_test", _params, socket) do
    case start_preview_execution(socket) do
      {:ok, socket} ->
        {:noreply, put_flash(socket, :info, "Test execution started")}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to start test: #{reason}")}
    end
  end

  @impl true
  def handle_event("run_node", %{"step_id" => step_id}, socket) do
    case start_partial_execution(socket, step_id) do
      {:ok, socket} ->
        {:noreply, put_flash(socket, :info, "Partial execution started")}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to run node: #{reason}")}
    end
  end

  @impl true
  def handle_event(
        "toggle_webhook_test",
        %{"action" => action, "step_id" => step_id} = params,
        socket
      ) do
    workflow_id = socket.assigns.workflow.id

    case action do
      "start" ->
        attrs = %{
          step_id: step_id,
          path: Map.get(params, "path"),
          method: Map.get(params, "method"),
          user_id: socket.assigns.current_user_id
        }

        case Server.enable_test_webhook(workflow_id, attrs) do
          {:ok, _} ->
            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Unable to enable test webhook: #{format_test_webhook_error(reason)}"
             )}
        end

      "stop" ->
        _ = Server.disable_test_webhook(workflow_id, step_id)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_execution", _params, socket) do
    case socket.assigns.execution do
      %Execution{} = execution ->
        _ = maybe_stop_execution_process(execution.id)

        case Executions.cancel_execution(socket.assigns.current_scope, execution) do
          {:ok, updated_execution} ->
            {:noreply, assign(socket, :execution, updated_execution)}

          {:error, :already_terminal} ->
            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Unable to cancel execution")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "preview_expression",
        %{"expression" => template, "step_id" => step_id, "field_key" => field_key},
        socket
      ) do
    result =
      ExpressionPreview.evaluate(
        %{
          workflow: socket.assigns.workflow,
          editor_state: socket.assigns.editor_state,
          execution: socket.assigns.execution,
          step_executions: socket.assigns.step_executions
        },
        template,
        step_id
      )

    # Update previews in socket assigns
    previews = socket.assigns.expression_previews
    new_previews = Map.put(previews, "#{step_id}:#{field_key}", result)

    {:noreply, assign(socket, :expression_previews, new_previews)}
  end

  @impl true
  def handle_event(
        "resolve_field_options",
        %{"resolver" => resolver, "params" => params, "q" => q},
        socket
      ) do
    # Add context from execution so resolvers can use upstream step output if needed
    context = %{
      execution: socket.assigns.execution,
      step_executions: socket.assigns.step_executions,
      workflow: socket.assigns.workflow,
      current_scope: socket.assigns.current_scope
    }

    # Safe params map (keys might come as strings from JS)
    safe_params = Map.new(params || %{}, fn {k, v} -> {to_string(k), v} end)

    args = %{
      q: q || "",
      params: safe_params,
      context: context
    }

    case Fizz.Steps.FieldResolver.resolve(resolver, args) do
      {:ok, options} ->
        {:reply, %{options: options}, socket}

      {:error, reason} ->
        Logger.error("Failed to resolve field options for #{resolver}: #{inspect(reason)}")
        {:reply, %{options: []}, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    _ = unsubscribe_execution(socket)

    if socket.assigns.webhook_execution_subscribed do
      ExecutionPubSub.unsubscribe_workflow_executions(socket.assigns.workflow.id)
    end

    :ok
  end

  # =============================================================================
  # PubSub Message Handlers
  # =============================================================================

  # Handle operation broadcasts from the edit session server
  @impl true
  def handle_info({:operation_applied, operation}, socket) do
    case Operations.apply(socket.assigns.workflow.draft, operation) do
      {:ok, new_draft} ->
        updated_workflow = %{socket.assigns.workflow | draft: new_draft}

        socket =
          socket
          |> assign(:workflow, updated_workflow)
          |> maybe_push_undo_state_for_operation(operation)

        {:noreply, socket}

      {:error, reason} ->
        Logger.error(
          "edit.ex: Failed to apply operation #{inspect(operation.type)}: #{inspect(reason)}. Reloading..."
        )

        # Fallback: reload from database
        case Workflows.get_workflow_with_draft(
               socket.assigns.current_scope,
               socket.assigns.workflow.id
             ) do
          {:ok, workflow} ->
            {:noreply, assign(socket, :workflow, workflow)}

          {:error, _} ->
            {:noreply, socket}
        end
    end
  end

  # Handle editor state updates (pins, disabled steps, locks)
  @impl true
  def handle_info({:editor_state_updated, new_editor_state}, socket) do
    socket =
      socket
      |> assign(:editor_state, new_editor_state)
      |> maybe_toggle_webhook_subscription(new_editor_state)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:webhook_test_execution, %{execution_id: execution_id}}, socket) do
    case Executions.get_execution(socket.assigns.current_scope, execution_id) do
      {:ok, execution} ->
        {:noreply, switch_to_execution(socket, execution)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # Handle Phoenix.Presence diff broadcasts
  # This is the standard format from Phoenix.Presence
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
    handle_presence_diff(socket, diff)
  end

  # Handle lock events
  @impl true
  def handle_info({:lock_acquired, step_id, user_id}, socket) do
    editor_state =
      EditorState.put_lock(socket.assigns.editor_state, step_id, user_id, DateTime.utc_now())

    {:noreply, assign(socket, :editor_state, editor_state)}
  end

  @impl true
  def handle_info({:lock_released, step_id}, socket) do
    editor_state = EditorState.release_lock(socket.assigns.editor_state, step_id)
    {:noreply, assign(socket, :editor_state, editor_state)}
  end

  # Handle sync state (for reconnection)
  @impl true
  def handle_info({:sync_state, state}, socket) do
    editor_state = deserialize_editor_state(state.editor_state, socket.assigns.workflow.id)

    socket =
      socket
      |> assign(:workflow, %{socket.assigns.workflow | draft: state.draft})
      |> assign(:editor_state, editor_state)
      |> maybe_toggle_webhook_subscription(editor_state)
      |> push_undo_state()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:execution_event, %{event_name: event_name} = event}, socket)
      when event_name in @execution_lifecycle_events do
    {:noreply, handle_execution_lifecycle_event(socket, event)}
  end

  @impl true
  def handle_info(
        {:execution_event, %{event_name: event_name, payload: payload}},
        socket
      )
      when event_name in @step_lifecycle_events do
    socket =
      if event_name == :step_failed do
        step_id = fetch_payload_value(payload, :step_id)
        error = fetch_payload_value(payload, :error)
        put_flash(socket, :error, "Step #{step_id} failed: #{format_error_message(error)}")
      else
        socket
      end

    {:noreply, update_step_executions(socket, event_name, payload)}
  end

  # Catch-all for unhandled messages (useful for debugging)
  @impl true
  def handle_info(msg, socket) do
    require Logger
    Logger.debug("Unhandled message in WorkflowLive.Edit: #{inspect(msg)}")
    {:noreply, socket}
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp format_validation_errors(errors) when is_list(errors) do
    errors
    |> Enum.take(3)
    |> Enum.map_join(", ", fn
      %{message: msg} -> msg
      msg when is_binary(msg) -> msg
      other -> inspect(other)
    end)
  end

  defp format_validation_errors(errors), do: inspect(errors)

  defp format_publish_error(:access_denied),
    do: "You don't have permission to publish this workflow"

  defp format_publish_error(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map_join(", ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  defp format_publish_error(reason), do: "Failed to publish: #{inspect(reason)}"

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

  defp build_duplicate_steps(steps, step_ids, position_by_step_id, group_id_by_step_id) do
    step_lookup = Map.new(steps, fn step -> {fetch_field(step, :id), step} end)

    {new_steps, id_map, group_id_by_new_step_id, _existing_steps} =
      Enum.reduce(step_ids, {[], %{}, %{}, steps}, fn step_id,
                                                      {acc, id_map, group_map, existing_steps} ->
        case Map.get(step_lookup, step_id) do
          nil ->
            {acc, id_map, group_map, existing_steps}

          step ->
            base_name = fetch_field(step, :name) || "Step"

            {unique_name, new_step_id} =
              Workflows.generate_unique_step_identity(existing_steps, base_name)

            group_map =
              case Map.get(group_id_by_step_id, step_id) do
                nil -> group_map
                group_id -> Map.put(group_map, new_step_id, group_id)
              end

            new_step = %{
              id: new_step_id,
              type_id: fetch_field(step, :type_id),
              name: unique_name,
              config: fetch_field(step, :config) || %{},
              position:
                resolve_duplicate_position(
                  position_by_step_id,
                  step_id,
                  fetch_field(step, :position)
                ),
              notes: fetch_field(step, :notes)
            }

            {[new_step | acc], Map.put(id_map, step_id, new_step_id), group_map,
             [new_step | existing_steps]}
        end
      end)

    {Enum.reverse(new_steps), id_map, group_id_by_new_step_id}
  end

  defp build_duplicate_connections(connections, step_ids, id_map) do
    selected_ids = MapSet.new(step_ids)

    connections
    |> Enum.reduce([], fn conn, acc ->
      target_id = fetch_field(conn, :target_step_id)

      if MapSet.member?(selected_ids, target_id) do
        source_id = fetch_field(conn, :source_step_id)
        new_target = Map.get(id_map, target_id)
        new_source = Map.get(id_map, source_id, source_id)

        if new_target && new_source do
          [
            %{
              id: UUID.generate(),
              source_step_id: new_source,
              target_step_id: new_target,
              source_output: fetch_field(conn, :source_output) || "main",
              target_input: fetch_field(conn, :target_input) || "main"
            }
            | acc
          ]
        else
          acc
        end
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp build_group_lookup(groups) do
    groups
    |> List.wrap()
    |> Enum.flat_map(fn group ->
      group_id = fetch_field(group, :id)
      step_ids = fetch_field(group, :step_ids) || []
      Enum.map(step_ids, &{&1, group_id})
    end)
    |> Map.new()
  end

  defp resolve_duplicate_position(position_by_step_id, step_id, fallback_position) do
    case fetch_field(position_by_step_id, step_id) do
      %{} = position -> normalize_position(position)
      _ -> offset_position(fallback_position)
    end
  end

  defp normalize_position(position) when is_map(position) do
    %{
      x: fetch_field(position, :x) || 0,
      y: fetch_field(position, :y) || 0
    }
  end

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

  defp normalize_group_changes(changes) when is_map(changes) do
    position =
      Map.get(changes, :position) ||
        Map.get(changes, "position")

    if is_map(position) do
      Map.put(changes, :position, normalize_group_position(position))
    else
      changes
    end
  end

  defp normalize_group_changes(_changes), do: %{}

  defp offset_position(position) do
    normalized = normalize_position(position || %{})
    %{x: normalized.x + 50, y: normalized.y + 50}
  end

  defp fetch_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp fetch_field(_map, _key), do: nil

  defp apply_operation(socket, type, payload) do
    operation = %{
      id: UUID.generate(),
      type: type,
      payload: payload,
      user_id: socket.assigns.current_user_id,
      client_seq: nil
    }

    case Server.apply_operation(socket.assigns.workflow.id, operation) do
      {:ok, _result} ->
        {:noreply, push_undo_state(socket)}

      {:error, reason} ->
        require Logger
        Logger.warning("Operation failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Operation failed")}
    end
  end

  defp parse_count(count) when is_integer(count) and count > 0, do: count

  defp parse_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {value, _} when value > 0 -> value
      _ -> 1
    end
  end

  defp parse_count(_count), do: 1

  defp push_undo_state(socket) do
    case Server.get_undo_state(socket.assigns.workflow.id, socket.assigns.current_user_id) do
      {:ok, undo_state} ->
        push_event(socket, "workflow:undo_state", undo_state)

      _ ->
        socket
    end
  end

  defp maybe_push_undo_state_for_operation(socket, operation) do
    if operation.user_id == socket.assigns.current_user_id do
      push_undo_state(socket)
    else
      socket
    end
  end

  defp refresh_workflow(socket) do
    case Workflows.get_workflow_with_draft(
           socket.assigns.current_scope,
           socket.assigns.workflow.id
         ) do
      {:ok, workflow} -> assign(socket, :workflow, workflow)
      {:error, _} -> socket
    end
  end

  defp webhook_listening?(socket) do
    case socket.assigns.editor_state do
      %EditorState{webhook_test: webhook_test} when not is_nil(webhook_test) -> true
      _ -> false
    end
  end

  defp maybe_toggle_webhook_subscription(socket, %EditorState{} = editor_state) do
    listening? = not is_nil(editor_state.webhook_test)
    subscribed? = socket.assigns.webhook_execution_subscribed

    cond do
      listening? and not subscribed? ->
        case ExecutionPubSub.subscribe_workflow_executions(
               socket.assigns.current_scope,
               socket.assigns.workflow.id
             ) do
          :ok -> assign(socket, :webhook_execution_subscribed, true)
          {:error, _} -> socket
        end

      not listening? and subscribed? ->
        ExecutionPubSub.unsubscribe_workflow_executions(socket.assigns.workflow.id)
        assign(socket, :webhook_execution_subscribed, false)

      true ->
        socket
    end
  end

  defp switch_to_execution(socket, %Execution{} = execution) do
    socket = unsubscribe_execution(socket)
    _ = subscribe_execution(socket.assigns.current_scope, execution.id)

    steps =
      case socket.assigns.workflow.draft do
        nil -> []
        draft -> draft.steps || []
      end

    step_executions = build_initial_step_executions(execution.id, steps)

    socket
    |> assign(:execution, execution)
    |> assign(:execution_id, execution.id)
    |> assign(:step_executions, step_executions)
    |> assign(:debug_execution_id, nil)
  end

  defp start_preview_execution(socket) do
    socket = unsubscribe_execution(socket)

    workflow = socket.assigns.workflow
    scope = socket.assigns.current_scope

    {draft, editor_state} =
      fetch_session_state(
        workflow.id,
        workflow.draft,
        socket.assigns.editor_state
      )

    workflow = %{workflow | draft: draft}

    socket =
      socket
      |> assign(:workflow, workflow)
      |> assign(:editor_state, editor_state)

    if is_nil(draft) do
      {:error, "workflow draft missing", socket}
    else
      preview_draft = build_preview_draft(draft, editor_state)
      pinned_outputs = editor_state.pinned_outputs || %{}
      pinned_steps = Map.keys(pinned_outputs)
      disabled_steps = MapSet.to_list(editor_state.disabled_steps || MapSet.new())
      trigger_data = find_trigger_data(preview_draft)

      attrs = %{
        workflow_id: workflow.id,
        execution_type: :preview,
        trigger: %{type: :manual, data: trigger_data},
        metadata: %{
          extras:
            build_editor_execution_extras(%{
              preview: true,
              pinned_steps: pinned_steps,
              disabled_steps: disabled_steps
            })
        }
      }

      with {:ok, execution} <- Executions.create_execution(scope, attrs) do
        try do
          with :ok <- subscribe_execution(scope, execution.id),
               {:ok, _pid} <-
                 start_execution_process(execution.id,
                   step_outputs: pinned_outputs,
                   source: preview_draft
                 ) do
            step_executions = build_initial_step_executions(execution.id, preview_draft.steps)

            socket =
              socket
              |> assign(:execution, execution)
              |> assign(:execution_id, execution.id)
              |> assign(:step_executions, step_executions)
              |> assign(:debug_execution_id, nil)

            {:ok, socket}
          else
            {:error, reason} ->
              _ = Executions.update_execution_status(scope, execution, :failed, error: reason)
              {:error, format_execution_error(reason), socket}
          end
        rescue
          e ->
            Logger.error("Crash during preview execution setup: #{inspect(e)}",
              stacktrace: __STACKTRACE__
            )

            _ = Executions.update_execution_status(scope, execution, :failed, error: e)
            {:error, "Crash during setup: #{inspect(e)}", socket}
        end
      else
        {:error, reason} ->
          {:error, format_execution_error(reason), socket}
      end
    end
  end

  defp start_partial_execution(socket, step_id) do
    socket = unsubscribe_execution(socket)

    workflow = socket.assigns.workflow
    scope = socket.assigns.current_scope

    {draft, editor_state} =
      fetch_session_state(
        workflow.id,
        workflow.draft,
        socket.assigns.editor_state
      )

    workflow = %{workflow | draft: draft}

    socket =
      socket
      |> assign(:workflow, workflow)
      |> assign(:editor_state, editor_state)

    if is_nil(draft) do
      {:error, "workflow draft missing", socket}
    else
      preview_draft = build_preview_draft(draft, editor_state)

      with {:ok, partial_draft} <- build_partial_draft(preview_draft, step_id),
           {:ok, execution} <-
             create_partial_execution(workflow.id, scope, partial_draft, step_id, editor_state) do
        try do
          with :ok <- subscribe_execution(scope, execution.id),
               {:ok, _pid} <-
                 start_execution_process(execution.id,
                   step_outputs: editor_state.pinned_outputs || %{},
                   source: partial_draft
                 ) do
            step_executions = build_initial_step_executions(execution.id, partial_draft.steps)

            socket =
              socket
              |> assign(:execution, execution)
              |> assign(:execution_id, execution.id)
              |> assign(:step_executions, step_executions)
              |> assign(:debug_execution_id, nil)

            {:ok, socket}
          else
            {:error, reason} ->
              _ = Executions.update_execution_status(scope, execution, :failed, error: reason)
              {:error, format_execution_error(reason), socket}
          end
        rescue
          e ->
            Logger.error("Crash during partial execution setup: #{inspect(e)}",
              stacktrace: __STACKTRACE__
            )

            _ = Executions.update_execution_status(scope, execution, :failed, error: e)
            {:error, "Crash during setup: #{inspect(e)}", socket}
        end
      else
        {:error, :step_not_found} ->
          {:error, "step not found or disabled", socket}

        {:error, reason} ->
          {:error, format_execution_error(reason), socket}
      end
    end
  end

  defp find_trigger_data(draft) do
    # Find the first manual_input step and extract its trigger_data config
    manual_input_step =
      Enum.find(draft.steps, fn step ->
        step.type_id == "manual_input"
      end)

    case manual_input_step do
      %{config: %{"trigger_data" => raw_json}} when is_binary(raw_json) ->
        case Jason.decode(raw_json) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end

      %{config: %{"trigger_data" => data}} when is_map(data) ->
        data

      _ ->
        %{}
    end
  end

  defp create_partial_execution(workflow_id, scope, draft, step_id, %EditorState{} = editor_state) do
    trigger_data = find_trigger_data(draft)
    pinned_outputs = editor_state.pinned_outputs || %{}
    pinned_steps = Map.keys(pinned_outputs)
    disabled_steps = MapSet.to_list(editor_state.disabled_steps || MapSet.new())

    attrs = %{
      workflow_id: workflow_id,
      execution_type: :partial,
      trigger: %{type: :manual, data: trigger_data},
      metadata: %{
        extras:
          build_editor_execution_extras(%{
            partial: true,
            target_step_id: step_id,
            pinned_steps: pinned_steps,
            disabled_steps: disabled_steps
          })
      }
    }

    Executions.create_execution(scope, attrs)
  end

  defp build_preview_draft(draft, %EditorState{} = editor_state) do
    disabled_steps = editor_state.disabled_steps || MapSet.new()

    steps =
      Enum.reject(draft.steps, fn step ->
        MapSet.member?(disabled_steps, step.id)
      end)

    step_ids = MapSet.new(Enum.map(steps, & &1.id))

    connections =
      Enum.filter(draft.connections, fn conn ->
        MapSet.member?(step_ids, conn.source_step_id) and
          MapSet.member?(step_ids, conn.target_step_id)
      end)

    %{draft | steps: steps, connections: connections}
  end

  defp build_partial_draft(draft, step_id) do
    steps = draft.steps || []
    connections = draft.connections || []
    graph = Fizz.Graph.from_workflow!(steps, connections, validate: false)

    if Fizz.Graph.has_vertex?(graph, step_id) do
      upstream = Fizz.Graph.upstream(graph, step_id)
      keep_ids = MapSet.new([step_id | upstream])

      filtered_steps = Enum.filter(steps, &MapSet.member?(keep_ids, &1.id))

      filtered_connections =
        Enum.filter(connections, fn conn ->
          MapSet.member?(keep_ids, conn.source_step_id) and
            MapSet.member?(keep_ids, conn.target_step_id)
        end)

      {:ok, %{draft | steps: filtered_steps, connections: filtered_connections}}
    else
      {:error, :step_not_found}
    end
  end

  defp build_initial_step_executions(execution_id, steps) do
    now = DateTime.utc_now()

    Enum.map(steps, fn step ->
      %{
        id: "#{execution_id}:#{step.id}",
        execution_id: execution_id,
        step_id: step.id,
        step_type_id: step.type_id,
        status: :pending,
        attempt: 1,
        input_data: nil,
        output_data: nil,
        output_item_count: nil,
        error: nil,
        queued_at: nil,
        started_at: nil,
        completed_at: nil,
        duration_us: nil,
        metadata: %{},
        inserted_at: now
      }
    end)
  end

  defp build_editor_execution_extras(extra_attrs) when is_map(extra_attrs) do
    Map.merge(%{request: build_mock_request()}, extra_attrs)
  end

  defp build_mock_request do
    %{
      "request_id" => "mock-request-" <> UUID.generate(),
      "headers" => %{"user-agent" => "Fizz Editor (Preview)"},
      "body" => %{}
    }
  end

  defp subscribe_execution(scope, execution_id) do
    case ExecutionPubSub.subscribe_execution(scope, execution_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp unsubscribe_execution(socket) do
    case socket.assigns.execution_id do
      nil ->
        socket

      execution_id ->
        ExecutionPubSub.unsubscribe_execution(execution_id)

        socket
        |> assign(:execution_id, nil)
        |> assign(:execution, nil)
        |> assign(:step_executions, [])
    end
  end

  defp start_execution_process(execution_id, opts) do
    case ExecutionSupervisor.start_execution(execution_id, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_stop_execution_process(execution_id) do
    case ExecutionSupervisor.get_execution_pid(execution_id) do
      {:ok, pid} ->
        Process.exit(pid, :shutdown)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp refresh_execution_from_event(socket, %{execution_id: execution_id}) do
    case Executions.get_execution(socket.assigns.current_scope, execution_id) do
      {:ok, execution} -> assign(socket, :execution, execution)
      {:error, _} -> socket
    end
  end

  defp handle_execution_lifecycle_event(socket, %{event_name: event_name} = event)
       when event_name in @execution_lifecycle_events do
    socket =
      case event_name do
        :execution_started ->
          maybe_switch_to_webhook_execution(socket, event)

        :execution_failed ->
          socket
          |> maybe_switch_to_webhook_execution(event)
          |> maybe_put_execution_failed_flash(event)

        _ ->
          socket
      end

    maybe_refresh_current_execution(socket, event)
  end

  defp maybe_refresh_current_execution(socket, %{execution_id: execution_id} = event) do
    if execution_id == socket.assigns.execution_id do
      refresh_execution_from_event(socket, event)
    else
      socket
    end
  end

  defp maybe_switch_to_webhook_execution(
         socket,
         %{execution_id: execution_id, workflow_id: workflow_id}
       ) do
    with true <- webhook_listening?(socket),
         true <- workflow_id == socket.assigns.workflow.id,
         false <- execution_id == socket.assigns.execution_id,
         {:ok, execution} <- Executions.get_execution(socket.assigns.current_scope, execution_id),
         true <- webhook_preview_execution?(execution) do
      switch_to_execution(socket, execution)
    else
      _ -> socket
    end
  end

  defp maybe_switch_to_webhook_execution(socket, _event), do: socket

  defp webhook_preview_execution?(%Execution{
         execution_type: :preview,
         trigger: %Execution.Trigger{type: :webhook}
       }),
       do: true

  defp webhook_preview_execution?(_execution), do: false

  defp maybe_put_execution_failed_flash(
         socket,
         %{event_name: :execution_failed, execution_id: execution_id, payload: payload}
       ) do
    if execution_id == socket.assigns.execution_id do
      error = fetch_payload_value(payload, :error) || payload
      put_flash(socket, :error, "Execution failed: #{format_error_message(error)}")
    else
      socket
    end
  end

  defp maybe_put_execution_failed_flash(socket, _event), do: socket

  defp update_step_executions(socket, event_name, payload) do
    step_executions =
      EditStepProjection.apply_event(
        socket.assigns.step_executions,
        socket.assigns.execution_id,
        event_name,
        payload
      )

    assign(socket, :step_executions, step_executions)
  end

  defp fetch_payload_value(payload, key) when is_map(payload) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(payload, key) -> Map.get(payload, key)
      Map.has_key?(payload, string_key) -> Map.get(payload, string_key)
      true -> nil
    end
  end

  defp fetch_payload_value(_payload, _key), do: nil

  defp payload_has_key?(payload, key) when is_map(payload) do
    Map.has_key?(payload, key) || Map.has_key?(payload, Atom.to_string(key))
  end

  defp payload_has_key?(_payload, _key), do: false

  defp parse_item_index(payload) do
    case fetch_payload_value(payload, :item_index) do
      nil ->
        nil

      index when is_integer(index) ->
        index

      index when is_binary(index) ->
        case Integer.parse(index) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp resolve_pin_output(step_executions, step_id, item_index) do
    candidates =
      step_executions
      |> Enum.filter(&step_execution_matches?(&1, step_id, item_index))
      |> then(fn matches ->
        if matches == [] and not is_nil(item_index) do
          Enum.filter(step_executions, &step_execution_matches?(&1, step_id, nil))
        else
          matches
        end
      end)

    case pick_latest_execution(candidates) do
      nil -> nil
      execution -> Map.get(execution, :output_data)
    end
  end

  defp step_execution_matches?(execution, step_id, nil) do
    Map.get(execution, :step_id) == step_id
  end

  defp step_execution_matches?(execution, step_id, item_index) do
    Map.get(execution, :step_id) == step_id and Map.get(execution, :item_index) == item_index
  end

  defp pick_latest_execution([]), do: nil

  defp pick_latest_execution(executions) do
    completed =
      Enum.filter(executions, fn execution ->
        status = Map.get(execution, :status)
        status in [:completed, "completed"]
      end)

    candidates = if completed == [], do: executions, else: completed

    Enum.max_by(candidates, &execution_timestamp/1, fn -> nil end)
  end

  defp execution_timestamp(execution) do
    completed_at = Map.get(execution, :completed_at)
    started_at = Map.get(execution, :started_at)
    inserted_at = Map.get(execution, :inserted_at)

    timestamp_from(completed_at) || timestamp_from(started_at) || timestamp_from(inserted_at) || 0
  end

  defp timestamp_from(nil), do: nil

  defp timestamp_from(%DateTime{} = datetime) do
    DateTime.to_unix(datetime, :millisecond)
  end

  defp timestamp_from(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp timestamp_from(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_unix(datetime, :millisecond)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, datetime} ->
            datetime
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.to_unix(:millisecond)

          _ ->
            nil
        end
    end
  end

  defp timestamp_from(_value), do: nil

  defp format_test_webhook_error(:webhook_not_found), do: "webhook trigger not found"
  defp format_test_webhook_error(:not_found), do: "edit session not running"
  defp format_test_webhook_error(reason), do: inspect(reason)

  defp format_execution_error(:access_denied), do: "access denied"
  defp format_execution_error(:workflow_not_found), do: "workflow not found"
  defp format_execution_error(:workflow_not_published), do: "workflow not published"
  defp format_execution_error(:unauthorized), do: "access denied"
  defp format_execution_error(:not_found), do: "execution not found"

  defp format_execution_error(%Ecto.Changeset{} = changeset) do
    error =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> inspect()

    "invalid execution: #{error}"
  end

  defp format_execution_error(reason), do: inspect(reason)

  defp handle_presence_diff(socket, _diff) do
    # Fetch latest full presence list
    presences = PresenceFormatter.format(Presence.list_users(socket.assigns.workflow.id))
    {:noreply, assign(socket, :presences, presences)}
  end

  defp deserialize_editor_state(nil, workflow_id) do
    %EditorState{workflow_id: workflow_id}
  end

  defp deserialize_editor_state(state, workflow_id) when is_map(state) do
    %EditorState{
      workflow_id: workflow_id,
      pinned_outputs: state[:pinned_outputs] || state["pinned_outputs"] || %{},
      disabled_steps: MapSet.new(state[:disabled_steps] || state["disabled_steps"] || []),
      step_locks: state[:step_locks] || state["step_locks"] || %{},
      webhook_test: state[:webhook_test] || state["webhook_test"]
    }
  end

  defp fetch_session_state(workflow_id, fallback_draft, fallback_editor_state) do
    try do
      case Server.get_sync_state(workflow_id) do
        {:ok, %{type: :full_sync, draft: draft, editor_state: editor_state}} ->
          draft = draft || fallback_draft
          {draft, deserialize_editor_state(editor_state, workflow_id)}

        _ ->
          {fallback_draft, fallback_editor_state}
      end
    catch
      :exit, _ -> {fallback_draft, fallback_editor_state}
    end
  end

  defp fetch_undo_state(workflow_id, user_id) do
    case Server.get_undo_state(workflow_id, user_id) do
      {:ok, undo_state} -> undo_state
      _ -> nil
    end
  end

  defp format_error_message(error) when is_binary(error), do: error
  defp format_error_message(%{message: message}), do: message
  defp format_error_message(%{"message" => message}), do: message
  defp format_error_message(error), do: inspect(error)
end
