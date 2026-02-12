defmodule Fizz.Sprites do
  @moduledoc """
  Workspace-scoped sprite management with provider-owned runtime state.
  """

  import Ecto.Query, warn: false

  alias Fizz.Accounts
  alias Fizz.Accounts.Scope
  alias Fizz.Repo
  alias FizzWeb.Presence

  alias Fizz.Sprites.{
    Console.Registry,
    Console.SessionServer,
    Console.Supervisor,
    ManagedSprite,
    SpriteConsoleChunk,
    SpriteCommand,
    SpriteEvent,
    SpriteSession
  }

  @default_egress_preset "minimal_agent"
  @default_console_grace_seconds 20
  @active_session_states ~w(starting attached grace_detaching detached)

  @type scope :: Scope.t()

  @spec resolve_workspace_scope(scope() | nil, String.t(), String.t()) ::
          {:ok, scope()} | {:error, term()}
  def resolve_workspace_scope(%Scope{} = scope, organization_id, workspace_id)
      when is_binary(organization_id) and is_binary(workspace_id) do
    with {:ok, resolved_scope} <-
           Accounts.build_scope(scope, organization_id, workspace_id: workspace_id),
         %{} <- resolved_scope.workspace,
         true <- can_read_scope?(resolved_scope) do
      {:ok, resolved_scope}
    else
      false -> {:error, :forbidden}
      nil -> {:error, :workspace_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_workspace_scope(_scope, _organization_id, _workspace_id),
    do: {:error, :unauthenticated}

  @spec list_sprites(scope(), map() | keyword()) :: {:ok, [%ManagedSprite{}]} | {:error, term()}
  def list_sprites(%Scope{} = scope, opts \\ %{}) do
    with :ok <- require_read(scope) do
      include_archived = truthy?(read_value(opts, [:include_archived, "include_archived"]))

      query =
        from(sprite in ManagedSprite,
          where: sprite.workspace_id == ^scope.workspace.id and is_nil(sprite.deleted_at),
          order_by: [asc: sprite.display_name]
        )
        |> maybe_exclude_archived(include_archived)

      sprites =
        query
        |> Repo.all()
        |> Enum.map(&hydrate_sprite/1)

      {:ok, sprites}
    end
  end

  @spec create_sprite(scope(), map(), keyword()) :: {:ok, %ManagedSprite{}} | {:error, term()}
  def create_sprite(%Scope{} = scope, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with :ok <- require_manage(scope),
         :ok <- ensure_provider_configured(),
         display_name when is_binary(display_name) <-
           normalize_display_name(read_value(attrs, [:display_name, "display_name"])),
         {:ok, managed_sprite} <- insert_managed_sprite(scope, attrs, display_name) do
      provider = provider_module()
      config = normalize_sprite_config(attrs, opts)

      case provider.create_sprite(managed_sprite.sprite_name, config) do
        {:ok, _payload} ->
          post_create = apply_post_create_defaults(provider, managed_sprite.sprite_name)

          metadata =
            merge_provisioning_warnings(managed_sprite.metadata, post_create.warnings)

          auth_mode =
            normalize_url_auth_mode(
              read_value(post_create.url_settings, [:auth, "auth"]) ||
                managed_sprite.url_auth_mode
            )

          with {:ok, updated_sprite} <-
                 update_managed_sprite(managed_sprite, %{
                   metadata: metadata,
                   url_auth_mode: auth_mode
                 }) do
            emit_event(updated_sprite, scope.user, "sprite.created", %{
              sprite_name: updated_sprite.sprite_name,
              provisioning_warnings: post_create.warnings
            })

            {:ok, hydrate_sprite(updated_sprite)}
          end

        {:error, reason} ->
          _ = Repo.delete(managed_sprite)
          {:error, reason}
      end
    else
      nil -> {:error, :display_name_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_sprite!(scope(), String.t(), keyword()) :: %ManagedSprite{}
  def get_sprite!(%Scope{} = scope, sprite_id, _opts \\ []) when is_binary(sprite_id) do
    case require_read(scope) do
      :ok ->
        scope
        |> fetch_sprite!(sprite_id)
        |> hydrate_sprite()

      {:error, reason} ->
        raise ArgumentError, "cannot load sprite: #{inspect(reason)}"
    end
  end

  @spec archive_sprite(scope(), String.t(), keyword()) ::
          {:ok, %ManagedSprite{}} | {:error, term()}
  def archive_sprite(%Scope{} = scope, sprite_id, _opts \\ []) when is_binary(sprite_id) do
    with :ok <- require_manage(scope),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id),
         {:ok, sprite} <- update_managed_sprite(sprite, %{archived_at: DateTime.utc_now()}) do
      emit_event(sprite, scope.user, "sprite.archived", %{})
      {:ok, hydrate_sprite(sprite)}
    end
  end

  @spec destroy_sprite(scope(), String.t(), keyword()) ::
          {:ok, %ManagedSprite{}} | {:error, term()}
  def destroy_sprite(%Scope{} = scope, sprite_id, _opts \\ []) when is_binary(sprite_id) do
    with :ok <- require_manage(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id),
         :ok <- provider_module().destroy_sprite(sprite.sprite_name),
         {:ok, sprite} <- update_managed_sprite(sprite, %{deleted_at: DateTime.utc_now()}) do
      emit_event(sprite, scope.user, "sprite.destroyed", %{})
      {:ok, hydrate_sprite(sprite)}
    end
  end

  @spec run_command(scope(), String.t(), map(), keyword()) ::
          {:ok, %{command: %SpriteCommand{}, output: binary(), exit_code: non_neg_integer()}}
          | {:error, term()}
  def run_command(%Scope{} = scope, sprite_id, attrs, opts \\ [])
      when is_binary(sprite_id) and is_map(attrs) do
    with :ok <- require_execute(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id),
         command when is_binary(command) and byte_size(command) > 0 <-
           read_value(attrs, [:command, "command"]),
         args <- normalize_args(read_value(attrs, [:args, "args"])),
         cwd <- normalize_cwd(read_value(attrs, [:cwd, "cwd"])),
         {:ok, record} <- insert_command_record(scope, sprite, command, args, cwd, "oneshot"),
         {:ok, result} <-
           provider_module().run_command(
             sprite.sprite_name,
             command,
             args,
             command_opts(cwd, opts)
           ),
         {:ok, updated_record} <-
           update_command_record(record, %{
             status: if(result.exit_code == 0, do: "completed", else: "failed"),
             exit_code: result.exit_code,
             finished_at: DateTime.utc_now()
           }) do
      emit_event(sprite, scope.user, "sprite.command.executed", %{
        command_id: updated_record.id,
        exit_code: result.exit_code
      })

      {:ok, %{command: updated_record, output: result.output, exit_code: result.exit_code}}
    else
      nil -> {:error, :command_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec open_console_client(scope(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def open_console_client(%Scope{} = scope, sprite_id, pane_id, client_id, opts \\ [])
      when is_binary(sprite_id) and is_binary(pane_id) and is_binary(client_id) and
             is_list(opts) do
    with :ok <- require_execute(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id),
         pane_id when is_binary(pane_id) <- normalize_pane_id(pane_id),
         command <- normalize_console_command(Keyword.get(opts, :command)),
         args <- normalize_console_args(command, normalize_args(Keyword.get(opts, :args, []))),
         focused <- truthy?(Keyword.get(opts, :focused, true)),
         {:ok, session} <- ensure_open_session(scope, sprite, pane_id, command, args),
         {:ok, session} <- ensure_session_runtime(scope, sprite, session, pane_id, command, args),
         {:ok, snapshot} <-
           SessionServer.register_client(
             session.id,
             scope.user.id,
             client_id,
             pane_id,
             self(),
             focused
           ),
         :ok <-
           track_console_presence(
             self(),
             session.id,
             client_id,
             scope.user.id,
             pane_id,
             focused
           ) do
      emit_event(sprite, scope.user, "sprite.console.client_opened", %{
        session_id: session.id,
        pane_id: pane_id
      })

      {:ok,
       %{
         session_id: snapshot.id,
         provider_session_id: snapshot.provider_session_id,
         generation: snapshot.generation,
         state: snapshot.state,
         lease_state: lease_state_for(snapshot.lease_client_id, client_id),
         lease_client_id: snapshot.lease_client_id,
         command: snapshot.command,
         chunks: snapshot.chunks
       }}
    end
  end

  @spec heartbeat_console_client(scope(), String.t(), String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def heartbeat_console_client(%Scope{} = scope, sprite_id, session_id, client_id, focused)
      when is_binary(sprite_id) and is_binary(session_id) and is_binary(client_id) and
             is_boolean(focused) do
    with :ok <- require_execute(scope),
         {:ok, _sprite} <- fetch_sprite(scope, sprite_id),
         :ok <- ensure_runtime_session_exists(scope, sprite_id, session_id),
         {:ok, lease} <- SessionServer.heartbeat(session_id, scope.user.id, client_id, focused),
         :ok <- update_console_presence(session_id, client_id, focused) do
      {:ok, Map.put(lease, :lease_state, lease_state_for(lease.lease_client_id, client_id))}
    end
  end

  @spec request_write_lease(scope(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_write_lease(%Scope{} = scope, sprite_id, session_id, client_id)
      when is_binary(sprite_id) and is_binary(session_id) and is_binary(client_id) do
    with :ok <- require_execute(scope),
         {:ok, _sprite} <- fetch_sprite(scope, sprite_id),
         :ok <- ensure_runtime_session_exists(scope, sprite_id, session_id),
         {:ok, lease} <- SessionServer.request_write_lease(session_id, scope.user.id, client_id) do
      {:ok, Map.put(lease, :lease_state, lease_state_for(lease.lease_client_id, client_id))}
    end
  end

  @spec send_console_input(scope(), String.t(), String.t(), String.t(), iodata()) ::
          :ok | {:error, term()}
  def send_console_input(%Scope{} = scope, sprite_id, session_id, client_id, data)
      when is_binary(sprite_id) and is_binary(session_id) and is_binary(client_id) do
    with :ok <- require_execute(scope),
         {:ok, _sprite} <- fetch_sprite(scope, sprite_id),
         :ok <- ensure_runtime_session_exists(scope, sprite_id, session_id),
         :ok <- SessionServer.send_input(session_id, scope.user.id, client_id, data) do
      :ok
    end
  end

  @spec resize_console(scope(), String.t(), String.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  def resize_console(%Scope{} = scope, sprite_id, session_id, client_id, rows, cols)
      when is_binary(sprite_id) and is_binary(session_id) and is_binary(client_id) and
             is_integer(rows) and is_integer(cols) do
    with :ok <- require_execute(scope),
         {:ok, _sprite} <- fetch_sprite(scope, sprite_id),
         :ok <- ensure_runtime_session_exists(scope, sprite_id, session_id),
         :ok <- SessionServer.resize(session_id, scope.user.id, client_id, rows, cols) do
      :ok
    end
  end

  @spec replay_console(scope(), String.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def replay_console(%Scope{} = scope, sprite_id, session_id, from_seq, opts \\ [])
      when is_binary(sprite_id) and is_binary(session_id) and is_integer(from_seq) and
             from_seq >= 0 do
    limit =
      Keyword.get(opts, :limit, 500)
      |> normalize_replay_limit()

    with :ok <- require_execute(scope),
         {:ok, _sprite} <- fetch_sprite(scope, sprite_id),
         {:ok, session} <- fetch_owned_session(scope, sprite_id, session_id),
         runtime_chunks <- replay_runtime_chunks(session_id, scope.user.id, from_seq, limit),
         db_chunks <- replay_persisted_chunks(session.id, from_seq, limit) do
      merged =
        (runtime_chunks ++ db_chunks)
        |> Enum.uniq_by(& &1.seq)
        |> Enum.sort_by(& &1.seq)
        |> Enum.take(limit)

      {:ok, merged}
    end
  end

  @spec terminate_console_session(scope(), String.t(), String.t()) :: :ok | {:error, term()}
  def terminate_console_session(%Scope{} = scope, sprite_id, session_id)
      when is_binary(sprite_id) and is_binary(session_id) do
    with :ok <- require_execute(scope),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id),
         {:ok, _session} <- fetch_owned_session(scope, sprite_id, session_id),
         :ok <- ensure_runtime_session_exists(scope, sprite_id, session_id),
         :ok <- SessionServer.terminate_session(session_id, scope.user.id, "terminated_by_user") do
      emit_event(sprite, scope.user, "sprite.console.terminated", %{session_id: session_id})
      :ok
    end
  end

  @spec list_sessions(scope(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_sessions(%Scope{} = scope, sprite_id, _opts \\ []) when is_binary(sprite_id) do
    with :ok <- require_read(scope),
         {:ok, _sprite} <- fetch_sprite(scope, sprite_id) do
      sessions =
        from(session in SpriteSession,
          where:
            session.owner_user_id == ^scope.user.id and
              session.managed_sprite_id == ^sprite_id,
          order_by: [desc: session.updated_at]
        )
        |> Repo.all()
        |> Enum.map(&sprite_session_to_map/1)

      {:ok, sessions}
    end
  end

  @spec list_checkpoints(scope(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_checkpoints(%Scope{} = scope, sprite_id, _opts \\ []) when is_binary(sprite_id) do
    with :ok <- require_read(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id) do
      provider_module().list_checkpoints(sprite.sprite_name)
    end
  end

  @spec get_checkpoint(scope(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_checkpoint(%Scope{} = scope, sprite_id, checkpoint_id, _opts \\ [])
      when is_binary(sprite_id) and is_binary(checkpoint_id) do
    with :ok <- require_read(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id) do
      provider_module().get_checkpoint(sprite.sprite_name, checkpoint_id)
    end
  end

  @spec create_checkpoint(scope(), String.t(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def create_checkpoint(%Scope{} = scope, sprite_id, attrs, _opts \\ [])
      when is_binary(sprite_id) and is_map(attrs) do
    with :ok <- require_manage(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id) do
      comment = normalize_comment(read_value(attrs, [:comment, "comment"]))

      opts =
        if is_binary(comment) and byte_size(comment) > 0 do
          [comment: comment]
        else
          []
        end

      case provider_module().create_checkpoint(sprite.sprite_name, opts) do
        {:ok, messages} ->
          emit_event(sprite, scope.user, "sprite.checkpoint.created", %{comment: comment})
          {:ok, messages}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec restore_checkpoint(scope(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def restore_checkpoint(%Scope{} = scope, sprite_id, checkpoint_id, _opts \\ [])
      when is_binary(sprite_id) and is_binary(checkpoint_id) do
    with :ok <- require_manage(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id) do
      case provider_module().restore_checkpoint(sprite.sprite_name, checkpoint_id) do
        {:ok, messages} ->
          emit_event(sprite, scope.user, "sprite.checkpoint.restored", %{
            checkpoint_id: checkpoint_id
          })

          {:ok, messages}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec get_network_policy(scope(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_network_policy(%Scope{} = scope, sprite_id, _opts \\ []) when is_binary(sprite_id) do
    with :ok <- require_read(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id) do
      provider_module().get_network_policy(sprite.sprite_name)
    end
  end

  @spec update_network_policy(scope(), String.t(), map(), keyword()) ::
          :ok | {:error, term()}
  def update_network_policy(%Scope{} = scope, sprite_id, policy, _opts \\ [])
      when is_binary(sprite_id) and is_map(policy) do
    with :ok <- require_manage(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id),
         normalized_policy <- normalize_policy(policy),
         :ok <- provider_module().update_network_policy(sprite.sprite_name, normalized_policy) do
      emit_event(sprite, scope.user, "sprite.network_policy.updated", normalized_policy)
      :ok
    end
  end

  @spec get_url_settings(scope(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_url_settings(%Scope{} = scope, sprite_id, _opts \\ []) when is_binary(sprite_id) do
    with :ok <- require_read(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id) do
      provider_module().get_url_settings(sprite.sprite_name)
    end
  end

  @spec update_url_settings(scope(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def update_url_settings(%Scope{} = scope, sprite_id, settings, _opts \\ [])
      when is_binary(sprite_id) and is_map(settings) do
    with :ok <- require_manage(scope),
         :ok <- ensure_provider_configured(),
         {:ok, sprite} <- fetch_sprite(scope, sprite_id),
         auth_mode <- normalize_url_auth_mode(read_value(settings, [:auth, "auth"])),
         :ok <- provider_module().update_url_settings(sprite.sprite_name, %{auth: auth_mode}),
         {:ok, _updated_sprite} <-
           update_managed_sprite(sprite, %{
             url_auth_mode: auth_mode
           }) do
      emit_event(sprite, scope.user, "sprite.url_settings.updated", %{auth: auth_mode})
      :ok
    end
  end

  @spec egress_presets() :: map()
  def egress_presets do
    Application.get_env(:fizz, :sprites_egress_presets, %{
      @default_egress_preset => %{
        "rules" => [
          %{"domain" => "api.openai.com", "action" => "allow"},
          %{"domain" => "api.anthropic.com", "action" => "allow"},
          %{"domain" => "api.github.com", "action" => "allow"},
          %{"domain" => "raw.githubusercontent.com", "action" => "allow"},
          %{"domain" => "registry.npmjs.org", "action" => "allow"},
          %{"domain" => "pypi.org", "action" => "allow"},
          %{"domain" => "files.pythonhosted.org", "action" => "allow"},
          %{"domain" => "*", "action" => "deny"}
        ]
      }
    })
  end

  defp hydrate_sprite(%ManagedSprite{} = sprite) do
    if provider_module().configured?() do
      case provider_module().get_sprite(sprite.sprite_name) do
        {:ok, remote_sprite} ->
          apply_runtime_sprite(sprite, remote_sprite)

        {:error, _reason} ->
          apply_runtime_sprite(sprite, nil, "unavailable")
      end
    else
      apply_runtime_sprite(sprite, nil, "unavailable")
    end
  end

  defp apply_runtime_sprite(
         %ManagedSprite{} = sprite,
         remote_sprite,
         fallback_status \\ "unknown"
       ) do
    remote_url_settings = read_value(remote_sprite, [:url_settings, "url_settings"]) || %{}

    remote_auth_mode =
      normalize_optional_url_auth_mode(read_value(remote_url_settings, [:auth, "auth"]))

    %{
      sprite
      | status:
          normalize_remote_status(read_value(remote_sprite, [:status, "status"])) ||
            fallback_status,
        url: read_value(remote_sprite, [:url, "url"]),
        url_auth_mode: remote_auth_mode || sprite.url_auth_mode
    }
  end

  defp insert_managed_sprite(scope, attrs, display_name) do
    description = read_value(attrs, [:description, "description"])
    now = DateTime.utc_now()

    %ManagedSprite{}
    |> ManagedSprite.create_changeset(%{
      workspace_id: scope.workspace.id,
      sprite_name: generate_sprite_name(display_name),
      display_name: display_name,
      description: description,
      url_auth_mode: "bearer",
      metadata: %{"created_at" => DateTime.to_iso8601(now)}
    })
    |> Repo.insert()
  end

  defp update_managed_sprite(sprite, attrs) do
    sprite
    |> ManagedSprite.changeset(attrs)
    |> Repo.update()
  end

  defp fetch_sprite(scope, sprite_id) do
    query =
      from(sprite in ManagedSprite,
        where:
          sprite.id == ^sprite_id and sprite.workspace_id == ^scope.workspace.id and
            is_nil(sprite.deleted_at)
      )

    case Repo.one(query) do
      %ManagedSprite{} = sprite -> {:ok, sprite}
      nil -> {:error, :sprite_not_found}
    end
  end

  defp fetch_sprite!(scope, sprite_id) do
    Repo.one!(
      from(sprite in ManagedSprite,
        where:
          sprite.id == ^sprite_id and sprite.workspace_id == ^scope.workspace.id and
            is_nil(sprite.deleted_at)
      )
    )
  end

  defp insert_command_record(scope, sprite, command, args, cwd, mode) do
    now = DateTime.utc_now()

    %SpriteCommand{}
    |> SpriteCommand.changeset(%{
      managed_sprite_id: sprite.id,
      actor_user_id: scope.user.id,
      command: command,
      args: args,
      cwd: cwd,
      mode: mode,
      status: "running",
      started_at: now
    })
    |> Repo.insert()
  end

  defp update_command_record(record, attrs) do
    record
    |> SpriteCommand.changeset(attrs)
    |> Repo.update()
  end

  defp emit_event(sprite, actor_user, event_type, payload) do
    actor_user_id =
      case actor_user do
        %{} -> actor_user.id
        _ -> nil
      end

    %SpriteEvent{}
    |> SpriteEvent.changeset(%{
      managed_sprite_id: sprite.id,
      actor_user_id: actor_user_id,
      event_type: event_type,
      severity: "info",
      payload: payload,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp ensure_open_session(scope, sprite, pane_id, command, args) do
    case latest_active_session(scope.user.id, sprite.id, pane_id) do
      %SpriteSession{} = session ->
        {:ok, session}

      nil ->
        create_console_session(scope, sprite, pane_id, command, args)
    end
  end

  defp latest_active_session(user_id, managed_sprite_id, pane_id) do
    from(session in SpriteSession,
      where:
        session.owner_user_id == ^user_id and
          session.managed_sprite_id == ^managed_sprite_id and
          session.pane_id == ^pane_id and
          session.state in ^@active_session_states,
      order_by: [desc: session.updated_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp create_console_session(scope, sprite, pane_id, command, args) do
    generation =
      from(session in SpriteSession,
        where:
          session.owner_user_id == ^scope.user.id and
            session.managed_sprite_id == ^sprite.id and
            session.pane_id == ^pane_id,
        select: max(session.generation)
      )
      |> Repo.one()
      |> case do
        nil -> 1
        value when is_integer(value) -> value + 1
      end

    %SpriteSession{}
    |> SpriteSession.changeset(%{
      managed_sprite_id: sprite.id,
      owner_user_id: scope.user.id,
      pane_id: pane_id,
      interactive_command: command,
      tty: true,
      state: "starting",
      generation: generation,
      metadata: %{"args" => args, "grace_seconds" => @default_console_grace_seconds},
      last_seq: 0
    })
    |> Repo.insert()
  end

  defp ensure_runtime_session(scope, sprite, session) do
    case Registry.whereis(session.id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_runtime_session(scope, sprite, session)
    end
  end

  defp ensure_session_runtime(scope, sprite, session, pane_id, command, args) do
    case ensure_runtime_session(scope, sprite, session) do
      {:ok, _pid} ->
        {:ok, session}

      {:error, _reason} ->
        with {:ok, replacement} <- create_console_session(scope, sprite, pane_id, command, args),
             {:ok, _pid} <- ensure_runtime_session(scope, sprite, replacement) do
          {:ok, replacement}
        end
    end
  end

  defp start_runtime_session(scope, sprite, session) do
    args =
      session.metadata
      |> read_value([:args, "args"])
      |> normalize_args()

    opts = [
      provider_module: provider_module(),
      sprite_name: sprite.sprite_name,
      session_id: session.id,
      owner_user_id: scope.user.id,
      command: session.interactive_command,
      tty: session.tty,
      generation: session.generation,
      next_seq: session.last_seq + 1,
      grace_seconds:
        read_value(session.metadata, [:grace_seconds, "grace_seconds"]) ||
          @default_console_grace_seconds
    ]

    mode_opts =
      case session.provider_session_id do
        provider_session_id when is_binary(provider_session_id) and provider_session_id != "" ->
          [mode: :attach, provider_session_id: provider_session_id]

        _ ->
          [mode: :start, args: args]
      end

    case Supervisor.start_session(opts ++ mode_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        mark_session_failed(session.id, reason)
        {:error, reason}
    end
  end

  defp ensure_runtime_session_exists(scope, sprite_id, session_id) do
    with {:ok, session} <- fetch_owned_session(scope, sprite_id, session_id),
         true <- is_pid(Registry.whereis(session.id)) do
      :ok
    else
      false -> {:error, :sprite_session_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_owned_session(scope, sprite_id, session_id) do
    query =
      from(session in SpriteSession,
        where:
          session.id == ^session_id and
            session.managed_sprite_id == ^sprite_id and
            session.owner_user_id == ^scope.user.id
      )

    case Repo.one(query) do
      %SpriteSession{} = session -> {:ok, session}
      nil -> {:error, :sprite_session_not_found}
    end
  end

  defp replay_runtime_chunks(session_id, user_id, from_seq, limit) do
    if is_pid(Registry.whereis(session_id)) do
      case SessionServer.replay(session_id, user_id, from_seq, limit) do
        {:ok, chunks} -> chunks
        _ -> []
      end
    else
      []
    end
  end

  defp replay_persisted_chunks(sprite_session_id, from_seq, limit) do
    from(chunk in SpriteConsoleChunk,
      where: chunk.sprite_session_id == ^sprite_session_id and chunk.seq > ^from_seq,
      order_by: [asc: chunk.seq],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn chunk -> %{seq: chunk.seq, stream: chunk.stream, data: chunk.data} end)
  end

  defp sprite_session_to_map(session) do
    %{
      id: session.id,
      provider_session_id: session.provider_session_id,
      pane_id: session.pane_id,
      interactive_command: session.interactive_command,
      state: session.state,
      generation: session.generation,
      lease_client_id: session.lease_client_id,
      tty: session.tty,
      last_seq: session.last_seq,
      last_activity_at: session.last_activity_at,
      closed_reason: session.closed_reason,
      exit_code: session.exit_code
    }
  end

  defp mark_session_failed(session_id, reason) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(session in SpriteSession, where: session.id == ^session_id),
      set: [state: "failed", closed_reason: inspect(reason), updated_at: now]
    )

    :ok
  end

  defp track_console_presence(pid, session_id, client_id, user_id, pane_id, focused) do
    topic = console_presence_topic(session_id)

    Presence.track(pid, topic, client_id, %{
      user_id: user_id,
      pane_id: pane_id,
      focused: focused,
      at: DateTime.utc_now()
    })
    |> case do
      {:ok, _meta} -> :ok
      {:error, {:already_tracked, _pid, _meta}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp update_console_presence(session_id, client_id, focused) do
    topic = console_presence_topic(session_id)

    Presence.update(self(), topic, client_id, fn meta ->
      Map.merge(meta, %{focused: focused, at: DateTime.utc_now()})
    end)
    |> case do
      {:ok, _meta} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp console_presence_topic(session_id), do: "sprites:console:session:#{session_id}"

  defp require_read(scope) do
    if can_read_scope?(scope), do: :ok, else: {:error, :forbidden}
  end

  defp require_execute(scope) do
    if can_execute_scope?(scope), do: :ok, else: {:error, :forbidden}
  end

  defp require_manage(scope) do
    if can_manage_scope?(scope), do: :ok, else: {:error, :forbidden}
  end

  defp can_read_scope?(%Scope{} = scope) do
    case scope.workspace_role do
      role when role in [:admin, :member, :viewer] -> true
      _ -> Scope.organization_admin?(scope)
    end
  end

  defp can_execute_scope?(%Scope{} = scope) do
    case scope.workspace_role do
      role when role in [:admin, :member] -> true
      _ -> Scope.organization_admin?(scope)
    end
  end

  defp can_manage_scope?(%Scope{} = scope) do
    Scope.organization_admin?(scope) || Scope.workspace_admin?(scope)
  end

  defp ensure_provider_configured do
    if provider_module().configured?() do
      :ok
    else
      {:error, :sprites_not_configured}
    end
  end

  defp provider_module do
    Application.get_env(:fizz, :sprites_provider_module, Fizz.Sprites.Providers.SpritesEx)
  end

  defp command_opts(cwd, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    base_opts = [timeout: timeout]

    if is_binary(cwd) and byte_size(cwd) > 0,
      do: Keyword.put(base_opts, :dir, cwd),
      else: base_opts
  end

  defp normalize_sprite_config(attrs, opts) do
    from_attrs =
      read_value(attrs, [:config, "config"])
      |> case do
        %{} = map -> map
        _ -> %{}
      end

    from_opts =
      Keyword.get(opts, :config, %{})
      |> case do
        %{} = map -> map
        _ -> %{}
      end

    Map.merge(from_opts, from_attrs)
  end

  defp normalize_policy(policy) do
    preset_name = read_value(policy, [:preset, "preset"])

    cond do
      is_binary(preset_name) and byte_size(preset_name) > 0 ->
        Map.get(egress_presets(), preset_name, default_egress_policy())

      true ->
        rules =
          read_value(policy, [:rules, "rules"])
          |> List.wrap()
          |> Enum.map(&normalize_policy_rule/1)
          |> Enum.reject(&is_nil/1)

        %{rules: rules}
    end
  end

  defp normalize_policy_rule(rule) when is_map(rule) do
    domain = read_value(rule, [:domain, "domain"])
    action = read_value(rule, [:action, "action"]) || "allow"
    include = read_value(rule, [:include, "include"])

    if is_binary(domain) and byte_size(domain) > 0 do
      base = %{domain: domain, action: action}

      if is_binary(include) and byte_size(include) > 0,
        do: Map.put(base, :include, include),
        else: base
    else
      nil
    end
  end

  defp normalize_policy_rule(_rule), do: nil

  defp default_egress_policy do
    Map.get(egress_presets(), @default_egress_preset, %{rules: [%{domain: "*", action: "deny"}]})
  end

  defp generate_sprite_name(display_name) do
    display_key =
      display_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> case do
        "" -> "sprite"
        value -> value
      end
      |> String.slice(0, 48)

    uid =
      System.unique_integer([:positive])
      |> Integer.to_string(36)
      |> String.downcase()

    "fizz-#{display_key}-#{uid}"
  end

  defp apply_post_create_defaults(provider, sprite_name) do
    warnings =
      case provider.update_network_policy(sprite_name, default_egress_policy()) do
        :ok -> []
        {:error, reason} -> [provisioning_warning("update_network_policy", reason)]
      end

    warnings =
      case provider.update_url_settings(sprite_name, %{auth: "bearer"}) do
        :ok ->
          warnings

        {:error, reason} ->
          warnings ++ [provisioning_warning("update_url_settings", reason)]
      end

    case provider.get_url_settings(sprite_name) do
      {:ok, url_settings} ->
        %{url_settings: url_settings, warnings: warnings}

      {:error, reason} ->
        %{
          url_settings: nil,
          warnings: warnings ++ [provisioning_warning("get_url_settings", reason)]
        }
    end
  end

  defp provisioning_warning(step, reason) do
    %{
      "step" => step,
      "reason" => inspect(reason)
    }
  end

  defp merge_provisioning_warnings(metadata, warnings) when is_list(warnings) do
    metadata = metadata || %{}

    case warnings do
      [] ->
        Map.delete(metadata, "provisioning_warnings")

      _ ->
        Map.put(metadata, "provisioning_warnings", warnings)
    end
  end

  defp normalize_display_name(display_name) when is_binary(display_name) do
    case String.trim(display_name) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_display_name(_display_name), do: nil

  defp normalize_args(args) when is_list(args) do
    args
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_args(args) when is_binary(args) do
    args
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_args(_args), do: []

  defp normalize_cwd(cwd) when is_binary(cwd) do
    value = String.trim(cwd)
    if value == "", do: nil, else: value
  end

  defp normalize_cwd(_cwd), do: nil

  defp normalize_console_command(command) when is_binary(command) do
    value = String.trim(command)
    if value == "", do: "bash", else: value
  end

  defp normalize_console_command(_command), do: "bash"

  defp normalize_console_args(command, args)
       when command in ["bash", "/bin/bash"] and is_list(args) and args == [],
       do: ["-i"]

  defp normalize_console_args(_command, args) when is_list(args), do: args

  defp normalize_pane_id(value) when is_binary(value) do
    value =
      value
      |> String.trim()

    if value == "" do
      nil
    else
      value
    end
  end

  defp normalize_pane_id(_value), do: nil

  defp normalize_replay_limit(value) when is_integer(value), do: min(max(value, 1), 2000)
  defp normalize_replay_limit(_value), do: 500

  defp lease_state_for(lease_client_id, client_id)
       when is_binary(lease_client_id) and is_binary(client_id) and lease_client_id == client_id,
       do: "writer"

  defp lease_state_for(_lease_client_id, _client_id), do: "viewer"

  defp normalize_comment(comment) when is_binary(comment) do
    case String.trim(comment) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_comment(_comment), do: nil

  defp normalize_url_auth_mode(mode) when mode in ["public", "bearer"], do: mode
  defp normalize_url_auth_mode(mode) when mode in [:public, :bearer], do: Atom.to_string(mode)
  defp normalize_url_auth_mode(_mode), do: "bearer"

  defp normalize_optional_url_auth_mode(mode) when mode in ["public", "bearer"], do: mode

  defp normalize_optional_url_auth_mode(mode) when mode in [:public, :bearer],
    do: Atom.to_string(mode)

  defp normalize_optional_url_auth_mode(_mode), do: nil

  defp normalize_remote_status(status) when is_binary(status) do
    status
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_remote_status(_status), do: nil

  defp maybe_exclude_archived(query, true), do: query

  defp maybe_exclude_archived(query, false) do
    from(sprite in query, where: is_nil(sprite.archived_at))
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp read_value(data, keys) do
    Enum.find_value(keys, fn key ->
      case data do
        %{} -> Map.get(data, key)
        list when is_list(list) -> Keyword.get(list, key)
        _ -> nil
      end
    end)
  end
end
