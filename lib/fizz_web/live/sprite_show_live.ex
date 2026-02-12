defmodule FizzWeb.SpriteShowLive do
  use FizzWeb, :live_view

  alias Fizz.Accounts.Scope
  alias Fizz.Sprites

  @impl true
  def mount(
        %{
          "organization_id" => organization_id,
          "workspace_id" => workspace_id,
          "id" => sprite_id
        },
        _session,
        socket
      ) do
    with {:ok, sprite_scope} <-
           Sprites.resolve_workspace_scope(
             socket.assigns.current_scope,
             organization_id,
             workspace_id
           ),
         sprite <- Sprites.get_sprite!(sprite_scope, sprite_id) do
      socket =
        socket
        |> assign(:page_title, "Sprite")
        |> assign(:organization_id, organization_id)
        |> assign(:workspace_id, workspace_id)
        |> assign(:sprite_scope, sprite_scope)
        |> assign(:sprite, sprite)
        |> assign(
          :command_form,
          command_form(%{"command" => "uname", "args" => "-a", "cwd" => ""})
        )
        |> assign(
          :console_form,
          console_form(%{"command" => "bash", "args" => "-i", "idle_timeout" => "60"})
        )
        |> assign(:checkpoint_form, checkpoint_form(%{"comment" => ""}))
        |> assign(:policy_form, policy_form(%{"preset" => "minimal_agent", "custom_rules" => ""}))
        |> assign(:url_form, url_form(%{"auth" => sprite.url_auth_mode || "bearer"}))
        |> assign(:command_result, nil)
        |> assign(:console_error, nil)
        |> assign(:policy_error, nil)
        |> assign(:checkpoint_error, nil)
        |> assign(:checkpoint_messages, [])
        |> assign(:active_session_id, nil)
        |> load_runtime_data()

      {:ok, socket}
    else
      _ ->
        socket =
          socket
          |> put_flash(:error, "Could not load this sprite in the selected workspace.")
          |> redirect(to: ~p"/sprites")

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("validate_command", %{"command" => command_params}, socket) do
    {:noreply, assign(socket, :command_form, command_form(command_params))}
  end

  def handle_event("run_command", %{"command" => command_params}, socket) do
    case Sprites.run_command(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           command_params
         ) do
      {:ok, result} ->
        {:noreply, assign(socket, :command_result, result)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Command failed: #{inspect(reason)}")}
    end
  end

  def handle_event("validate_console", %{"console" => console_params}, socket) do
    {:noreply, assign(socket, :console_form, console_form(console_params))}
  end

  def handle_event("start_console", %{"console" => console_params}, socket) do
    case Sprites.start_console(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           console_params
         ) do
      {:ok, session} ->
        socket =
          socket
          |> assign(:active_session_id, session.id)
          |> assign(:console_error, nil)
          |> maybe_subscribe_console(session.id)
          |> load_sessions()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :console_error, reason)}
    end
  end

  def handle_event("attach_console", %{"session-id" => session_id}, socket) do
    case Sprites.attach_console(socket.assigns.sprite_scope, socket.assigns.sprite.id, session_id) do
      {:ok, _session} ->
        socket =
          socket
          |> assign(:active_session_id, session_id)
          |> assign(:console_error, nil)
          |> maybe_subscribe_console(session_id)
          |> load_sessions()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :console_error, reason)}
    end
  end

  def handle_event("detach_console", _params, socket) do
    socket =
      case socket.assigns.active_session_id do
        nil ->
          socket

        session_id ->
          _ =
            Sprites.detach_console(
              socket.assigns.sprite_scope,
              socket.assigns.sprite.id,
              session_id,
              self()
            )

          assign(socket, :active_session_id, nil)
      end

    {:noreply, socket}
  end

  def handle_event("close_console", %{"session-id" => session_id}, socket) do
    socket =
      case Sprites.close_console(
             socket.assigns.sprite_scope,
             socket.assigns.sprite.id,
             session_id
           ) do
        :ok ->
          socket
          |> assign(:active_session_id, nil)
          |> load_sessions()

        {:error, reason} ->
          assign(socket, :console_error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("kill_console", %{"session-id" => session_id}, socket) do
    socket =
      case Sprites.kill_console(
             socket.assigns.sprite_scope,
             socket.assigns.sprite.id,
             session_id
           ) do
        :ok ->
          socket
          |> clear_active_session(session_id)
          |> assign(:console_error, nil)
          |> load_sessions()

        {:error, reason} ->
          assign(socket, :console_error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("console_input", %{"session_id" => session_id, "data" => data}, socket) do
    case Sprites.send_console_input(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           session_id,
           data
         ) do
      :ok ->
        {:noreply, socket}

      {:error, :sprite_session_not_found} ->
        {:noreply,
         socket
         |> clear_active_session(session_id)
         |> assign(:console_error, :sprite_session_not_found)
         |> load_sessions()}

      {:error, reason} ->
        {:noreply, assign(socket, :console_error, reason)}
    end
  end

  def handle_event(
        "console_resize",
        %{"session_id" => session_id, "rows" => rows, "cols" => cols},
        socket
      ) do
    rows = parse_positive_integer(rows, 24)
    cols = parse_positive_integer(cols, 80)

    _ =
      Sprites.resize_console(
        socket.assigns.sprite_scope,
        socket.assigns.sprite.id,
        session_id,
        rows,
        cols
      )

    {:noreply, socket}
  end

  def handle_event("validate_checkpoint", %{"checkpoint" => checkpoint_params}, socket) do
    {:noreply, assign(socket, :checkpoint_form, checkpoint_form(checkpoint_params))}
  end

  def handle_event("create_checkpoint", %{"checkpoint" => checkpoint_params}, socket) do
    case Sprites.create_checkpoint(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           checkpoint_params
         ) do
      {:ok, messages} ->
        socket =
          socket
          |> assign(:checkpoint_messages, messages)
          |> assign(:checkpoint_error, nil)
          |> assign(:checkpoint_form, checkpoint_form(%{"comment" => ""}))
          |> load_checkpoints()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :checkpoint_error, reason)}
    end
  end

  def handle_event("restore_checkpoint", %{"checkpoint-id" => checkpoint_id}, socket) do
    case Sprites.restore_checkpoint(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           checkpoint_id
         ) do
      {:ok, messages} ->
        socket =
          socket
          |> assign(:checkpoint_messages, messages)
          |> assign(:checkpoint_error, nil)
          |> load_checkpoints()
          |> load_sessions()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :checkpoint_error, reason)}
    end
  end

  def handle_event("validate_policy", %{"policy" => policy_params}, socket) do
    {:noreply, assign(socket, :policy_form, policy_form(policy_params))}
  end

  def handle_event("update_policy", %{"policy" => policy_params}, socket) do
    policy = build_policy_update(policy_params)

    socket =
      case Sprites.update_network_policy(
             socket.assigns.sprite_scope,
             socket.assigns.sprite.id,
             policy
           ) do
        :ok ->
          socket
          |> assign(:policy_error, nil)
          |> load_network_policy()

        {:error, reason} ->
          assign(socket, :policy_error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("validate_url", %{"url" => url_params}, socket) do
    {:noreply, assign(socket, :url_form, url_form(url_params))}
  end

  def handle_event("update_url", %{"url" => url_params}, socket) do
    socket =
      case Sprites.update_url_settings(
             socket.assigns.sprite_scope,
             socket.assigns.sprite.id,
             url_params
           ) do
        :ok ->
          socket
          |> assign(:sprite, %{
            socket.assigns.sprite
            | url_auth_mode: normalize_auth(url_params["auth"])
          })
          |> load_url_settings()

        {:error, reason} ->
          put_flash(socket, :error, "Could not update URL settings: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:console_output, session_id, chunk}, socket) do
    socket =
      if socket.assigns.active_session_id == session_id do
        push_event(socket, "console_output", %{session_id: session_id, chunk: chunk})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:console_exit, session_id, exit_code, reason}, socket) do
    socket =
      socket
      |> push_event("console_exit", %{
        session_id: session_id,
        exit_code: exit_code,
        reason: reason
      })
      |> assign(:active_session_id, nil)
      |> load_sessions()

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_runtime_data(socket) do
    socket
    |> load_sessions()
    |> load_checkpoints()
    |> load_network_policy()
    |> load_url_settings()
  end

  defp load_sessions(socket) do
    case Sprites.list_sessions(socket.assigns.sprite_scope, socket.assigns.sprite.id) do
      {:ok, sessions} ->
        assign(socket, :sessions, sessions)

      {:error, _reason} ->
        assign(socket, :sessions, [])
    end
  end

  defp load_checkpoints(socket) do
    case Sprites.list_checkpoints(socket.assigns.sprite_scope, socket.assigns.sprite.id) do
      {:ok, checkpoints} ->
        assign(socket, :checkpoints, checkpoints)

      {:error, reason} ->
        socket
        |> assign(:checkpoints, [])
        |> assign(:checkpoint_error, reason)
    end
  end

  defp load_network_policy(socket) do
    case Sprites.get_network_policy(socket.assigns.sprite_scope, socket.assigns.sprite.id) do
      {:ok, policy} ->
        assign(socket, :network_policy, policy)

      {:error, reason} ->
        socket
        |> assign(:network_policy, %{rules: []})
        |> assign(:policy_error, reason)
    end
  end

  defp load_url_settings(socket) do
    case Sprites.get_url_settings(socket.assigns.sprite_scope, socket.assigns.sprite.id) do
      {:ok, url_settings} ->
        socket
        |> assign(:url_settings, url_settings)
        |> assign(:url_form, url_form(%{"auth" => url_settings[:auth] || "bearer"}))

      {:error, _reason} ->
        assign(socket, :url_settings, %{
          auth: socket.assigns.sprite.url_auth_mode || "bearer",
          url: nil
        })
    end
  end

  defp maybe_subscribe_console(socket, session_id) do
    case Sprites.subscribe_console(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           session_id,
           self()
         ) do
      {:ok, chunks} ->
        push_event(socket, "console_bootstrap", %{session_id: session_id, chunks: chunks})

      {:error, reason} ->
        assign(socket, :console_error, reason)
    end
  end

  defp command_form(command_params) do
    to_form(command_params, as: :command)
  end

  defp console_form(console_params) do
    to_form(console_params, as: :console)
  end

  defp checkpoint_form(checkpoint_params) do
    to_form(checkpoint_params, as: :checkpoint)
  end

  defp policy_form(policy_params) do
    to_form(policy_params, as: :policy)
  end

  defp url_form(url_params) do
    to_form(url_params, as: :url)
  end

  defp build_policy_update(policy_params) do
    preset = policy_params["preset"]
    custom_rules = policy_params["custom_rules"] || ""

    if is_binary(custom_rules) and String.trim(custom_rules) != "" do
      rules =
        custom_rules
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          %{
            domain: String.trim(line),
            action: "allow"
          }
        end)
        |> Enum.reject(fn rule -> rule.domain == "" end)
        |> Kernel.++([%{domain: "*", action: "deny"}])

      %{rules: rules}
    else
      %{preset: preset}
    end
  end

  defp normalize_auth("public"), do: "public"
  defp normalize_auth(_), do: "bearer"

  defp parse_positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp parse_positive_integer(_value, fallback), do: fallback

  defp can_manage?(scope) do
    Scope.organization_admin?(scope) || Scope.workspace_admin?(scope)
  end

  defp can_execute?(scope) do
    can_manage?(scope) || scope.workspace_role == :member
  end

  defp clear_active_session(socket, session_id) do
    if socket.assigns.active_session_id == session_id do
      assign(socket, :active_session_id, nil)
    else
      socket
    end
  end

  defp timeout_options do
    [
      {"60 seconds", "60"},
      {"5 minutes", "300"},
      {"15 minutes", "900"},
      {"1 hour", "3600"},
      {"Never", "never"}
    ]
  end

  defp console_error_message(:sprites_not_configured),
    do: "Sprites is not configured for this environment."

  defp console_error_message(:provider_session_unavailable),
    do: "This session cannot be attached because no provider session ID is available."

  defp console_error_message(:sprite_session_not_found),
    do: "This console session is no longer available. Start or attach another session."

  defp console_error_message(:forbidden),
    do: "You are not allowed to control this console session."

  defp console_error_message(_reason),
    do: "Could not manage the console session right now."
end
