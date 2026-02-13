defmodule FizzWeb.SpritesLive do
  use FizzWeb, :live_view

  alias Fizz.Accounts
  alias Fizz.Sprites

  @console_rows 28
  @console_cols 120

  @impl true
  def mount(_params, _session, socket) do
    organizations = Accounts.list_user_workos_organizations(socket.assigns.current_scope)

    socket =
      socket
      |> assign(:page_title, "Sprites")
      |> assign(:sprites_configured?, Sprites.configured?())
      |> assign(:organizations, organizations)
      |> assign(:selected_organization_id, nil)
      |> assign(:workspaces, [])
      |> assign(:selected_workspace_id, nil)
      |> assign(:resolved_scope, nil)
      |> assign(:workspace_error, nil)
      |> assign(:sprites_error, nil)
      |> assign(:sessions_error, nil)
      |> assign(:checkpoints_error, nil)
      |> assign(:console, nil)
      |> assign(:console_status, :idle)
      |> assign(:console_attached_session_id, nil)
      |> assign(:last_exec_result, nil)
      |> assign(:sprite_count, 0)
      |> assign(:session_count, 0)
      |> assign(:checkpoint_count, 0)
      |> assign(:latest_checkpoint_messages, [])
      |> assign_exec_form()
      |> assign_console_input_form()
      |> assign_checkpoint_form()
      |> stream(:sprites, [])
      |> stream(:sessions, [])
      |> stream(:checkpoints, [])
      |> stream(:console_output, [])
      |> maybe_auto_select_organization(organizations)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_organization", %{"organization_id" => org_id}, socket) do
    socket =
      socket
      |> stop_console()
      |> select_organization(org_id)

    {:noreply, socket}
  end

  def handle_event("select_workspace", %{"workspace_id" => ws_id}, socket) do
    socket =
      socket
      |> stop_console()
      |> select_workspace(ws_id)

    {:noreply, socket}
  end

  def handle_event("refresh_workspace", _params, socket) do
    {:noreply, refresh_dashboard_data(socket)}
  end

  def handle_event("ensure_sprite", _params, socket) do
    socket =
      case socket.assigns.resolved_scope do
        %{} = scope ->
          sprite_name = Sprites.workspace_sprite_name(scope)

          case Sprites.ensure_sprite(scope) do
            {:ok, _sprite} ->
              put_flash(socket, :info, "Sprite #{sprite_name} is ready")

            {:error, reason} ->
              put_flash(socket, :error, error_message(reason))
          end

        _ ->
          put_flash(socket, :error, "Select an organization and workspace first.")
      end

    {:noreply, refresh_dashboard_data(socket)}
  end

  def handle_event("destroy_sprite", _params, socket) do
    socket =
      socket
      |> stop_console()
      |> then(fn updated_socket ->
        case updated_socket.assigns.resolved_scope do
          %{} = scope ->
            sprite_name = Sprites.workspace_sprite_name(scope)

            case Sprites.destroy_sprite(scope) do
              :ok ->
                put_flash(updated_socket, :info, "Destroyed sprite #{sprite_name}")

              {:error, reason} ->
                put_flash(updated_socket, :error, error_message(reason))
            end

          _ ->
            put_flash(updated_socket, :error, "Select an organization and workspace first.")
        end
      end)

    {:noreply, refresh_dashboard_data(socket)}
  end

  def handle_event("run_exec", %{"exec" => %{"command" => command}}, socket) do
    command = String.trim(command || "")

    socket =
      cond do
        command == "" ->
          put_flash(socket, :error, "Command cannot be empty")

        socket.assigns.resolved_scope == nil ->
          put_flash(socket, :error, "Select an organization and workspace first.")

        true ->
          case Sprites.exec(socket.assigns.resolved_scope, command) do
            {:ok, %{stdout: stdout, exit_code: exit_code}} ->
              assign(socket, :last_exec_result, %{
                command: command,
                stdout: stdout,
                exit_code: exit_code
              })

            {:error, reason} ->
              put_flash(socket, :error, error_message(reason))
          end
      end

    {:noreply, socket |> assign_exec_form(command) |> refresh_dashboard_data()}
  end

  def handle_event("open_console", _params, socket) do
    socket =
      socket
      |> stop_console()
      |> open_new_console()

    {:noreply, socket |> refresh_dashboard_data()}
  end

  def handle_event("attach_session", %{"session-id" => session_id}, socket) do
    socket =
      socket
      |> stop_console()
      |> attach_existing_session(session_id)

    {:noreply, socket |> refresh_dashboard_data()}
  end

  def handle_event("console_stdin", %{"console_input" => %{"input" => input}}, socket) do
    trimmed_input = String.trim_trailing(input || "")

    socket =
      if trimmed_input == "" do
        socket
      else
        with {:ok, command} <- fetch_console_command(socket),
             :ok <- Sprites.write_console(command, trimmed_input <> "\n") do
          append_console_output(socket, :stdin, "$ #{trimmed_input}")
        else
          {:error, reason} -> put_flash(socket, :error, error_message(reason))
        end
      end

    {:noreply, assign_console_input_form(socket)}
  end

  def handle_event("close_console_stdin", _params, socket) do
    socket =
      case fetch_console_command(socket) do
        {:ok, command} ->
          :ok = Sprites.close_console(command)
          assign(socket, :console_status, :stdin_closed)

        {:error, _reason} ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("stop_console", _params, socket) do
    {:noreply, stop_console(socket)}
  end

  def handle_event("create_checkpoint", %{"checkpoint" => %{"comment" => comment}}, socket) do
    socket =
      case socket.assigns.resolved_scope do
        %{} = scope ->
          case Sprites.create_checkpoint(scope, comment) do
            {:ok, messages} ->
              socket
              |> assign(:latest_checkpoint_messages, messages)
              |> put_flash(:info, "Checkpoint created")

            {:error, reason} ->
              put_flash(socket, :error, error_message(reason))
          end

        _ ->
          put_flash(socket, :error, "Select an organization and workspace first.")
      end

    {:noreply, socket |> assign_checkpoint_form() |> refresh_dashboard_data()}
  end

  def handle_event("restore_checkpoint", %{"checkpoint-id" => checkpoint_id}, socket) do
    socket =
      case socket.assigns.resolved_scope do
        %{} = scope ->
          case Sprites.restore_checkpoint(scope, checkpoint_id) do
            {:ok, messages} ->
              socket
              |> assign(:latest_checkpoint_messages, messages)
              |> put_flash(:info, "Checkpoint restored")

            {:error, reason} ->
              put_flash(socket, :error, error_message(reason))
          end

        _ ->
          put_flash(socket, :error, "Select an organization and workspace first.")
      end

    {:noreply, refresh_dashboard_data(socket)}
  end

  @impl true
  def handle_info({:stdout, %{ref: ref}, data}, socket) do
    {:noreply, maybe_append_console_stream(socket, ref, :stdout, data)}
  end

  def handle_info({:stderr, %{ref: ref}, data}, socket) do
    {:noreply, maybe_append_console_stream(socket, ref, :stderr, data)}
  end

  def handle_info({:exit, %{ref: ref}, code}, socket) do
    socket =
      if console_ref(socket) == ref do
        socket
        |> assign(:console_status, :exited)
        |> append_console_output(:exit, "Console exited with status #{code}")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:error, %{ref: ref}, reason}, socket) do
    socket =
      if console_ref(socket) == ref do
        socket
        |> assign(:console_status, :error)
        |> append_console_output(:error, "Console error: #{inspect(reason)}")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, socket) do
    socket =
      case socket.assigns.console do
        %{monitor_ref: ^monitor_ref} ->
          socket
          |> assign(:console, nil)
          |> assign(:console_status, :disconnected)
          |> assign(:console_attached_session_id, nil)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Organization / workspace selection

  defp maybe_auto_select_organization(socket, [first | _]) do
    select_organization(socket, first.organization_id)
  end

  defp maybe_auto_select_organization(socket, _organizations), do: socket

  defp select_organization(socket, org_id) do
    scope = socket.assigns.current_scope

    case Accounts.build_scope(scope, org_id) do
      {:ok, org_scope} ->
        case Accounts.list_workspaces(org_scope) do
          {:ok, workspaces} ->
            socket
            |> assign(:selected_organization_id, org_id)
            |> assign(:workspaces, workspaces)
            |> assign(:selected_workspace_id, nil)
            |> assign(:resolved_scope, nil)
            |> assign(:workspace_error, nil)
            |> reset_dashboard_streams()
            |> maybe_auto_select_workspace(org_scope, workspaces)

          {:error, reason} ->
            socket
            |> assign(:selected_organization_id, org_id)
            |> assign(:workspaces, [])
            |> assign(:selected_workspace_id, nil)
            |> assign(:resolved_scope, nil)
            |> assign(:workspace_error, reason)
            |> reset_dashboard_streams()
        end

      {:error, reason} ->
        socket
        |> assign(:selected_organization_id, nil)
        |> assign(:workspaces, [])
        |> assign(:selected_workspace_id, nil)
        |> assign(:resolved_scope, nil)
        |> assign(:workspace_error, reason)
        |> reset_dashboard_streams()
    end
  end

  defp maybe_auto_select_workspace(socket, org_scope, [first | _]) do
    resolve_workspace_scope(socket, org_scope, first)
  end

  defp maybe_auto_select_workspace(socket, _org_scope, _workspaces), do: socket

  defp select_workspace(socket, ws_id) do
    org_id = socket.assigns.selected_organization_id
    scope = socket.assigns.current_scope

    case Accounts.build_scope(scope, org_id) do
      {:ok, org_scope} ->
        case Enum.find(socket.assigns.workspaces, &(to_string(&1.id) == ws_id)) do
          nil ->
            socket
            |> assign(:selected_workspace_id, nil)
            |> assign(:resolved_scope, nil)
            |> assign(:workspace_error, :workspace_not_found)
            |> reset_dashboard_streams()

          workspace ->
            resolve_workspace_scope(socket, org_scope, workspace)
        end

      {:error, reason} ->
        socket
        |> assign(:resolved_scope, nil)
        |> assign(:workspace_error, reason)
        |> reset_dashboard_streams()
    end
  end

  defp resolve_workspace_scope(socket, org_scope, workspace) do
    case Accounts.build_scope(
           socket.assigns.current_scope,
           org_scope.organization_id,
           workspace_id: workspace.id
         ) do
      {:ok, resolved_scope} ->
        socket
        |> assign(:selected_workspace_id, workspace.id)
        |> assign(:resolved_scope, resolved_scope)
        |> assign(:workspace_error, nil)
        |> refresh_dashboard_data()

      {:error, reason} ->
        socket
        |> assign(:selected_workspace_id, workspace.id)
        |> assign(:resolved_scope, nil)
        |> assign(:workspace_error, reason)
        |> reset_dashboard_streams()
    end
  end

  # Console

  defp open_new_console(socket) do
    case socket.assigns.resolved_scope do
      %{} = scope ->
        case Sprites.spawn_console(scope, self(),
               rows: @console_rows,
               cols: @console_cols,
               detachable: false
             ) do
          {:ok, command} ->
            console = build_console_state(command, :owned, nil)

            socket
            |> assign(:console, console)
            |> assign(:console_status, :running)
            |> assign(:console_attached_session_id, nil)
            |> stream(:console_output, [], reset: true)
            |> append_console_output(:info, "Console connected")

          {:error, reason} ->
            put_flash(socket, :error, error_message(reason))
        end

      _ ->
        put_flash(socket, :error, "Select an organization and workspace first.")
    end
  end

  defp attach_existing_session(socket, session_id) do
    case socket.assigns.resolved_scope do
      %{} = scope ->
        case Sprites.attach_console(scope, session_id, self(),
               rows: @console_rows,
               cols: @console_cols
             ) do
          {:ok, command} ->
            console = build_console_state(command, :attached, session_id)

            socket
            |> assign(:console, console)
            |> assign(:console_status, :running)
            |> assign(:console_attached_session_id, session_id)
            |> stream(:console_output, [], reset: true)
            |> append_console_output(:info, "Attached to session #{session_id}")

          {:error, reason} ->
            put_flash(socket, :error, error_message(reason))
        end

      _ ->
        put_flash(socket, :error, "Select an organization and workspace first.")
    end
  end

  defp build_console_state(command, mode, session_id) do
    monitor_ref =
      case command_pid(command) do
        pid when is_pid(pid) -> Process.monitor(pid)
        _ -> nil
      end

    %{
      command: command,
      command_ref: command_ref(command),
      monitor_ref: monitor_ref,
      mode: mode,
      session_id: session_id
    }
  end

  defp stop_console(socket) do
    case socket.assigns.console do
      %{command: command, monitor_ref: monitor_ref} ->
        pid = command_pid(command)

        if is_pid(pid) do
          Process.exit(pid, :normal)
        end

        if is_reference(monitor_ref) do
          Process.demonitor(monitor_ref, [:flush])
        end

        socket
        |> assign(:console, nil)
        |> assign(:console_status, :idle)
        |> assign(:console_attached_session_id, nil)

      _ ->
        socket
    end
  end

  # Dashboard data refresh

  defp refresh_dashboard_data(socket) do
    socket
    |> refresh_sprites_stream()
    |> refresh_sessions_stream()
    |> refresh_checkpoints_stream()
  end

  defp reset_dashboard_streams(socket) do
    socket
    |> assign(:sprite_count, 0)
    |> assign(:session_count, 0)
    |> assign(:checkpoint_count, 0)
    |> assign(:sprites_error, nil)
    |> assign(:sessions_error, nil)
    |> assign(:checkpoints_error, nil)
    |> assign(:last_exec_result, nil)
    |> stream(:sprites, [], reset: true)
    |> stream(:sessions, [], reset: true)
    |> stream(:checkpoints, [], reset: true)
  end

  defp refresh_sprites_stream(%{assigns: %{resolved_scope: nil}} = socket) do
    socket
    |> assign(:sprites_error, nil)
    |> assign(:sprite_count, 0)
    |> stream(:sprites, [], reset: true)
  end

  defp refresh_sprites_stream(socket) do
    case Sprites.list_workspace_sprites(socket.assigns.resolved_scope) do
      {:ok, sprites} ->
        socket
        |> assign(:sprites_error, nil)
        |> assign(:sprite_count, length(sprites))
        |> stream(:sprites, sprites, reset: true)

      {:error, reason} ->
        socket
        |> assign(:sprites_error, reason)
        |> assign(:sprite_count, 0)
        |> stream(:sprites, [], reset: true)
    end
  end

  defp refresh_sessions_stream(%{assigns: %{resolved_scope: nil}} = socket) do
    socket
    |> assign(:sessions_error, nil)
    |> assign(:session_count, 0)
    |> stream(:sessions, [], reset: true)
  end

  defp refresh_sessions_stream(socket) do
    case Sprites.list_sessions(socket.assigns.resolved_scope) do
      {:ok, sessions} ->
        entries = Enum.map(sessions, &ensure_id(&1, "session"))

        socket
        |> assign(:sessions_error, nil)
        |> assign(:session_count, length(entries))
        |> stream(:sessions, entries, reset: true)

      {:error, reason} ->
        socket
        |> assign(:sessions_error, reason)
        |> assign(:session_count, 0)
        |> stream(:sessions, [], reset: true)
    end
  end

  defp refresh_checkpoints_stream(%{assigns: %{resolved_scope: nil}} = socket) do
    socket
    |> assign(:checkpoints_error, nil)
    |> assign(:checkpoint_count, 0)
    |> stream(:checkpoints, [], reset: true)
  end

  defp refresh_checkpoints_stream(socket) do
    case Sprites.list_checkpoints(socket.assigns.resolved_scope) do
      {:ok, checkpoints} ->
        entries = Enum.map(checkpoints, &ensure_id(&1, "checkpoint"))

        socket
        |> assign(:checkpoints_error, nil)
        |> assign(:checkpoint_count, length(entries))
        |> stream(:checkpoints, entries, reset: true)

      {:error, reason} ->
        socket
        |> assign(:checkpoints_error, reason)
        |> assign(:checkpoint_count, 0)
        |> stream(:checkpoints, [], reset: true)
    end
  end

  # Console stream helpers

  defp maybe_append_console_stream(socket, ref, kind, data) do
    if console_ref(socket) == ref do
      append_console_output(socket, kind, data)
    else
      socket
    end
  end

  defp append_console_output(socket, kind, data) do
    entry = %{
      id: "console-#{System.unique_integer([:positive])}",
      kind: kind,
      data: normalize_console_data(data),
      inserted_at: DateTime.utc_now(:second)
    }

    stream_insert(socket, :console_output, entry)
  end

  defp console_ref(%{assigns: %{console: %{command_ref: ref}}}), do: ref
  defp console_ref(_socket), do: nil

  defp command_ref(%{ref: ref}), do: ref
  defp command_ref(_command), do: nil

  defp command_pid(%{pid: pid}) when is_pid(pid), do: pid
  defp command_pid(_command), do: nil

  defp fetch_console_command(%{assigns: %{console: %{command: command}}}), do: {:ok, command}
  defp fetch_console_command(_socket), do: {:error, :no_console}

  # Form helpers

  defp assign_exec_form(socket, command \\ nil) do
    value =
      cond do
        is_binary(command) -> command
        is_map(socket.assigns[:last_exec_result]) -> socket.assigns.last_exec_result.command
        true -> ""
      end

    assign(socket, :exec_form, to_form(%{"command" => value}, as: :exec))
  end

  defp assign_console_input_form(socket) do
    assign(socket, :console_input_form, to_form(%{"input" => ""}, as: :console_input))
  end

  defp assign_checkpoint_form(socket) do
    assign(socket, :checkpoint_form, to_form(%{"comment" => ""}, as: :checkpoint))
  end

  defp ensure_id(entry, prefix) do
    case Map.get(entry, :id) do
      id when is_binary(id) and id != "" -> entry
      _ -> Map.put(entry, :id, "#{prefix}-#{System.unique_integer([:positive])}")
    end
  end

  defp normalize_console_data(data) when is_binary(data), do: String.trim_trailing(data, "\n")
  defp normalize_console_data(data), do: to_string(data)

  defp error_message(:sprites_not_configured),
    do: "Sprites is not configured. Set SPRITES_API_KEY."

  defp error_message(:forbidden), do: "You are not allowed to access this resource."
  defp error_message(:workspace_scope_required), do: "Select an organization and workspace first."
  defp error_message(:organization_scope_required), do: "Select an organization first."
  defp error_message(:no_console), do: "Open a console session first."
  defp error_message({:exec_failed, reason}), do: "Command failed: #{reason}"
  defp error_message({:list_failed, reason}), do: "Could not list sprites: #{reason}"
  defp error_message({:api_error, _status, _body}), do: "Sprites API request failed."
  defp error_message({:not_found, _body}), do: "Sprite not found."
  defp error_message(reason), do: "Operation failed: #{inspect(reason)}"
end
