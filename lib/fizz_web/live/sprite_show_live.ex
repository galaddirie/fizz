defmodule FizzWeb.SpriteShowLive do
  use FizzWeb, :live_view

  alias Fizz.Accounts.Scope
  alias Fizz.Sprites

  @default_pane_id "pane-1"

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
        |> assign(:checkpoint_form, checkpoint_form(%{"comment" => ""}))
        |> assign(:policy_form, policy_form(%{"preset" => "minimal_agent", "custom_rules" => ""}))
        |> assign(:url_form, url_form(%{"auth" => sprite.url_auth_mode || "bearer"}))
        |> assign(:command_result, nil)
        |> assign(:console_error, nil)
        |> assign(:policy_error, nil)
        |> assign(:checkpoint_error, nil)
        |> assign(:checkpoint_messages, [])
        |> assign(:split_consoles, false)
        |> assign(:active_pane_id, @default_pane_id)
        |> assign(:panes, [new_pane(@default_pane_id, 1)])
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

  def handle_event("console_add_tab", _params, socket) do
    next_index = length(socket.assigns.panes) + 1
    pane_id = "pane-#{System.unique_integer([:positive])}"

    pane = new_pane(pane_id, next_index)

    socket =
      socket
      |> update(:panes, fn panes -> panes ++ [pane] end)
      |> assign(:active_pane_id, pane_id)

    {:noreply, socket}
  end

  def handle_event("console_focus_tab", %{"pane-id" => pane_id}, socket) do
    {:noreply, assign(socket, :active_pane_id, pane_id)}
  end

  def handle_event("console_split_toggle", _params, socket) do
    {:noreply, assign(socket, :split_consoles, !socket.assigns.split_consoles)}
  end

  def handle_event("console_close_tab", %{"pane-id" => pane_id}, socket) do
    {pane, remaining} = pop_pane(socket.assigns.panes, pane_id)

    socket =
      case pane do
        nil ->
          socket

        pane ->
          maybe_unregister_client(socket, pane)

          active_pane_id =
            if socket.assigns.active_pane_id == pane_id do
              case remaining do
                [first | _] -> first.id
                [] -> nil
              end
            else
              socket.assigns.active_pane_id
            end

          socket
          |> assign(:panes, remaining)
          |> assign(:active_pane_id, active_pane_id)
      end

    {:noreply, socket}
  end

  def handle_event(
        "console_client_init",
        %{"pane_id" => pane_id, "client_id" => client_id} = params,
        socket
      ) do
    focused = truthy?(params["focused"])
    last_seq = parse_non_neg_integer(params["last_seq"], 0)

    with {:ok, pane} <- fetch_pane(socket.assigns.panes, pane_id),
         {:ok, opened} <-
           Sprites.open_console_client(
             socket.assigns.sprite_scope,
             socket.assigns.sprite.id,
             pane_id,
             client_id,
             command: "bash",
             args: ["-i"],
             focused: focused
           ) do
      message = console_bootstrap_message(pane, opened.session_id)

      {socket, chunks} = load_replay(socket, opened.session_id, last_seq, opened.chunks)

      socket =
        socket
        |> assign(:console_error, nil)
        |> put_pane(pane_id, fn existing ->
          existing
          |> Map.put(:client_id, client_id)
          |> Map.put(:session_id, opened.session_id)
          |> Map.put(:provider_session_id, opened.provider_session_id)
          |> Map.put(:generation, opened.generation)
          |> Map.put(:state, opened.state)
          |> Map.put(:lease_state, opened.lease_state)
          |> Map.put(:lease_client_id, opened.lease_client_id)
          |> Map.put(:last_seq, max_known_seq(chunks, existing.last_seq || 0))
          |> Map.put(:status_message, message)
        end)
        |> load_sessions()
        |> push_event("console_v2_bootstrap", %{
          pane_id: pane_id,
          session_id: opened.session_id,
          generation: opened.generation,
          lease_state: opened.lease_state,
          message: message,
          chunks: chunks
        })

      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :console_error, reason)}
    end
  end

  def handle_event(
        "console_heartbeat",
        %{"pane_id" => pane_id, "session_id" => session_id, "client_id" => client_id} = params,
        socket
      ) do
    focused = truthy?(params["focused"])

    case Sprites.heartbeat_console_client(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           session_id,
           client_id,
           focused
         ) do
      {:ok, lease} ->
        socket =
          socket
          |> put_pane(pane_id, fn pane ->
            pane
            |> Map.put(:state, lease.state)
            |> Map.put(:lease_client_id, lease.lease_client_id)
            |> Map.put(:lease_state, lease.lease_state)
          end)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :console_error, reason)}
    end
  end

  def handle_event(
        "console_take_lease",
        %{"pane_id" => pane_id, "session_id" => session_id, "client_id" => client_id},
        socket
      ) do
    case Sprites.request_write_lease(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           session_id,
           client_id
         ) do
      {:ok, lease} ->
        socket =
          socket
          |> assign(:console_error, nil)
          |> put_pane(pane_id, fn pane ->
            pane
            |> Map.put(:lease_client_id, lease.lease_client_id)
            |> Map.put(:lease_state, lease.lease_state)
          end)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :console_error, reason)}
    end
  end

  def handle_event(
        "console_input",
        %{
          "pane_id" => pane_id,
          "session_id" => session_id,
          "client_id" => client_id,
          "data" => data
        },
        socket
      ) do
    case Sprites.send_console_input(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           session_id,
           client_id,
           data
         ) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:console_error, reason)
          |> put_pane(pane_id, fn pane ->
            Map.put(pane, :status_message, console_input_error_message(reason))
          end)

        {:noreply, socket}
    end
  end

  def handle_event(
        "console_resize",
        %{
          "session_id" => session_id,
          "client_id" => client_id,
          "rows" => rows,
          "cols" => cols
        },
        socket
      ) do
    rows = parse_positive_integer(rows, 24)
    cols = parse_positive_integer(cols, 80)

    _ =
      Sprites.resize_console(
        socket.assigns.sprite_scope,
        socket.assigns.sprite.id,
        session_id,
        client_id,
        rows,
        cols
      )

    {:noreply, socket}
  end

  def handle_event(
        "console_replay",
        %{"pane_id" => pane_id, "session_id" => session_id, "from_seq" => from_seq},
        socket
      ) do
    from_seq = parse_non_neg_integer(from_seq, 0)

    case Sprites.replay_console(
           socket.assigns.sprite_scope,
           socket.assigns.sprite.id,
           session_id,
           from_seq,
           limit: 1000
         ) do
      {:ok, chunks} ->
        socket =
          socket
          |> put_pane(pane_id, fn pane ->
            Map.put(pane, :last_seq, max_known_seq(chunks, pane.last_seq || 0))
          end)
          |> push_event("console_v2_replay", %{
            pane_id: pane_id,
            session_id: session_id,
            chunks: chunks
          })

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :console_error, reason)}
    end
  end

  def handle_event("console_terminate", params, socket) do
    pane_id = params["pane_id"] || params["pane-id"]

    with {:ok, pane} <- fetch_pane(socket.assigns.panes, pane_id),
         session_id when is_binary(session_id) <- pane.session_id,
         :ok <-
           Sprites.terminate_console_session(
             socket.assigns.sprite_scope,
             socket.assigns.sprite.id,
             session_id
           ) do
      socket =
        socket
        |> put_pane(pane_id, fn existing ->
          existing
          |> Map.put(:state, "ended")
          |> Map.put(:status_message, "Previous session ended. Started a new session.")
        end)
        |> assign(:console_error, nil)
        |> load_sessions()

      {:noreply, socket}
    else
      nil -> {:noreply, assign(socket, :console_error, :sprite_session_not_found)}
      {:error, reason} -> {:noreply, assign(socket, :console_error, reason)}
    end
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
  def handle_info({:console_session_event, session_id, %{type: "output_chunk"} = event}, socket) do
    chunk = event.chunk

    socket =
      socket
      |> put_panes_for_session(session_id, fn pane ->
        Map.put(pane, :last_seq, max(chunk.seq, pane.last_seq || 0))
      end)
      |> push_event("console_v2_output", %{session_id: session_id, chunk: chunk})

    {:noreply, socket}
  end

  def handle_info({:console_session_event, session_id, %{type: "lease_changed"} = event}, socket) do
    socket =
      socket
      |> put_panes_for_session(session_id, fn pane ->
        lease_state =
          if pane.client_id == event.lease_client_id do
            "writer"
          else
            "viewer"
          end

        pane
        |> Map.put(:lease_client_id, event.lease_client_id)
        |> Map.put(:lease_state, lease_state)
      end)
      |> push_event("console_v2_lease", %{
        session_id: session_id,
        lease_client_id: event.lease_client_id
      })

    {:noreply, socket}
  end

  def handle_info({:console_session_event, session_id, %{type: "session_state"} = event}, socket) do
    socket =
      socket
      |> put_panes_for_session(session_id, fn pane -> Map.put(pane, :state, event.state) end)
      |> push_event("console_v2_state", %{
        session_id: session_id,
        state: event.state,
        reason: event[:reason]
      })

    {:noreply, socket}
  end

  def handle_info({:console_session_event, session_id, %{type: "session_exit"} = event}, socket) do
    socket =
      socket
      |> put_panes_for_session(session_id, fn pane ->
        pane
        |> Map.put(:state, "ended")
        |> Map.put(:status_message, "Previous session ended. Started a new session.")
      end)
      |> push_event("console_v2_exit", %{
        session_id: session_id,
        reason: event.reason,
        exit_code: event.exit_code
      })
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

  defp command_form(command_params), do: to_form(command_params, as: :command)
  defp checkpoint_form(checkpoint_params), do: to_form(checkpoint_params, as: :checkpoint)
  defp policy_form(policy_params), do: to_form(policy_params, as: :policy)
  defp url_form(url_params), do: to_form(url_params, as: :url)

  defp build_policy_update(policy_params) do
    preset = policy_params["preset"]
    custom_rules = policy_params["custom_rules"] || ""

    if is_binary(custom_rules) and String.trim(custom_rules) != "" do
      rules =
        custom_rules
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          %{domain: String.trim(line), action: "allow"}
        end)
        |> Enum.reject(fn rule -> rule.domain == "" end)
        |> Kernel.++([%{domain: "*", action: "deny"}])

      %{rules: rules}
    else
      %{preset: preset}
    end
  end

  defp rendered_panes(panes, active_pane_id, split?) do
    case Enum.find(panes, &(&1.id == active_pane_id)) do
      nil ->
        Enum.take(panes, 1)

      active_pane when split? ->
        [active_pane | panes]
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(2)

      active_pane ->
        [active_pane]
    end
  end

  defp new_pane(id, index) do
    %{
      id: id,
      label: "Console #{index}",
      client_id: nil,
      session_id: nil,
      provider_session_id: nil,
      generation: nil,
      state: "starting",
      lease_state: "viewer",
      lease_client_id: nil,
      last_seq: 0,
      status_message: nil
    }
  end

  defp put_pane(socket, pane_id, fun) when is_function(fun, 1) do
    assign(
      socket,
      :panes,
      Enum.map(socket.assigns.panes, fn pane ->
        if pane.id == pane_id, do: fun.(pane), else: pane
      end)
    )
  end

  defp put_panes_for_session(socket, session_id, fun) when is_function(fun, 1) do
    assign(
      socket,
      :panes,
      Enum.map(socket.assigns.panes, fn pane ->
        if pane.session_id == session_id, do: fun.(pane), else: pane
      end)
    )
  end

  defp fetch_pane(panes, pane_id) do
    case Enum.find(panes, &(&1.id == pane_id)) do
      nil -> {:error, :pane_not_found}
      pane -> {:ok, pane}
    end
  end

  defp pop_pane(panes, pane_id) do
    pane = Enum.find(panes, &(&1.id == pane_id))
    {pane, Enum.reject(panes, &(&1.id == pane_id))}
  end

  defp maybe_unregister_client(socket, %{session_id: session_id, client_id: client_id})
       when is_binary(session_id) and is_binary(client_id) do
    _ =
      Fizz.Sprites.Console.SessionServer.unregister_client(
        session_id,
        socket.assigns.sprite_scope.user.id,
        client_id
      )

    _ = FizzWeb.Presence.untrack(self(), "sprites:console:session:#{session_id}", client_id)

    socket
  end

  defp maybe_unregister_client(socket, _pane), do: socket

  defp load_replay(socket, session_id, last_seq, fallback_chunks) do
    if last_seq > 0 do
      case Sprites.replay_console(
             socket.assigns.sprite_scope,
             socket.assigns.sprite.id,
             session_id,
             last_seq,
             limit: 1000
           ) do
        {:ok, chunks} when chunks != [] -> {socket, chunks}
        _ -> {socket, fallback_chunks}
      end
    else
      {socket, fallback_chunks}
    end
  end

  defp max_known_seq(chunks, fallback) do
    chunks
    |> Enum.map(&Map.get(&1, :seq, fallback))
    |> Enum.max(fn -> fallback end)
  end

  defp console_bootstrap_message(%{session_id: nil}, _session_id),
    do: "Reconnected. Terminal resumed."

  defp console_bootstrap_message(%{session_id: session_id}, session_id)
       when is_binary(session_id),
       do: "Reattached to existing session (#{short_session_id(session_id)})."

  defp console_bootstrap_message(_pane, _session_id),
    do: "Previous session ended. Started a new session."

  defp short_session_id(session_id) when is_binary(session_id) do
    session_id
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> String.slice(0, 8)
  end

  defp short_session_id(_session_id), do: "unknown"

  defp console_input_error_message(:write_lease_required),
    do: "View-only. Click Take Control to type."

  defp console_input_error_message(:sprite_session_not_found),
    do: "Session not found. Reconnecting..."

  defp console_input_error_message(_reason), do: "Could not send input right now."

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

  defp parse_non_neg_integer(value, _fallback) when is_integer(value) and value >= 0, do: value

  defp parse_non_neg_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> fallback
    end
  end

  defp parse_non_neg_integer(_value, fallback), do: fallback

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp can_manage?(scope) do
    Scope.organization_admin?(scope) || Scope.workspace_admin?(scope)
  end

  defp can_execute?(scope) do
    can_manage?(scope) || scope.workspace_role == :member
  end

  defp console_error_message(:sprites_not_configured),
    do: "Sprites is not configured for this environment."

  defp console_error_message(:write_lease_required),
    do: "This pane is view-only. Click Take Control to send input."

  defp console_error_message(:sprite_session_not_found),
    do: "This console session is no longer available."

  defp console_error_message(:forbidden),
    do: "You are not allowed to control this console session."

  defp console_error_message(_reason),
    do: "Could not manage the console session right now."
end
