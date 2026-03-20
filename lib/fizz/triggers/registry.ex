defmodule Fizz.Triggers.Registry do
  @moduledoc """
  ETS-backed cache of active trigger registrations.
  """

  use GenServer

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Triggers.TriggerRegistration

  require Logger

  @notification_channel "trigger_registrations"
  @default_refresh_interval_ms :timer.seconds(60)
  @registration_table :fizz_trigger_registrations
  @webhook_table :fizz_trigger_registrations_by_webhook
  @project_kind_table :fizz_trigger_registrations_by_project_kind
  @project_table :fizz_trigger_registrations_by_project

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec refresh(keyword()) :: :ok
  def refresh(opts \\ []) do
    GenServer.call(server_name(opts), :refresh, :infinity)
  end

  @spec get_by_webhook_path(String.t()) :: {:ok, TriggerRegistration.t()} | :error
  def get_by_webhook_path(path) when is_binary(path) do
    case table_lookup(@webhook_table, path) do
      [{^path, registration}] -> {:ok, registration}
      _ -> :error
    end
  end

  @spec list_by_kind(String.t(), atom() | String.t()) :: [TriggerRegistration.t()]
  def list_by_kind(project_id, kind) when is_binary(project_id) do
    kind =
      case kind do
        value when is_atom(value) -> Atom.to_string(value)
        value when is_binary(value) -> value
      end

    @project_kind_table
    |> table_lookup({project_id, kind})
    |> Enum.map(fn {{^project_id, ^kind}, registration} -> registration end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @spec list_by_project(String.t()) :: [TriggerRegistration.t()]
  def list_by_project(project_id) when is_binary(project_id) do
    @project_table
    |> table_lookup(project_id)
    |> Enum.map(fn {^project_id, registration} -> registration end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @impl true
  def init(opts) do
    create_table(@registration_table, [:named_table, :set, :protected, read_concurrency: true])
    create_table(@webhook_table, [:named_table, :set, :protected, read_concurrency: true])
    create_table(@project_kind_table, [:named_table, :bag, :protected, read_concurrency: true])
    create_table(@project_table, [:named_table, :bag, :protected, read_concurrency: true])

    state = %{
      refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms),
      notifications?: Keyword.get(opts, :notifications?, true),
      notifications_pid: nil,
      listen_ref: nil
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    state =
      case load_registrations(state) do
        :ok ->
          connect_notifications(state)

        {:error, reason} ->
          Logger.warning("trigger registry bootstrap failed: #{inspect(reason)}")
          connect_notifications(state)
      end

    schedule_refresh(state.refresh_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    _ = load_registrations(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    _ = load_registrations(state)
    schedule_refresh(state.refresh_interval_ms)
    {:noreply, state}
  end

  def handle_info({:notification, _pid, _ref, @notification_channel, _payload}, state) do
    _ = load_registrations(state)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("trigger registry ignoring message: #{inspect(message)}")
    {:noreply, state}
  end

  defp load_registrations(_state) do
    registrations =
      TriggerRegistration
      |> where([registration], registration.status == "active")
      |> Repo.all()

    rebuild_cache(registrations)
    :ok
  rescue
    error -> {:error, error}
  end

  defp rebuild_cache(registrations) do
    :ets.delete_all_objects(@registration_table)
    :ets.delete_all_objects(@webhook_table)
    :ets.delete_all_objects(@project_kind_table)
    :ets.delete_all_objects(@project_table)

    Enum.each(registrations, fn registration ->
      :ets.insert(@registration_table, {registration.id, registration})

      :ets.insert(
        @project_kind_table,
        {{registration.project_id, registration.kind}, registration}
      )

      :ets.insert(@project_table, {registration.project_id, registration})

      if is_binary(registration.webhook_path) and registration.webhook_path != "" do
        :ets.insert(@webhook_table, {registration.webhook_path, registration})
      end
    end)

    :ok
  end

  defp connect_notifications(%{notifications?: false} = state), do: state

  defp connect_notifications(state) do
    with {:ok, pid} <- Postgrex.Notifications.start_link(notification_config()),
         {:ok, ref} <- Postgrex.Notifications.listen(pid, @notification_channel) do
      %{state | notifications_pid: pid, listen_ref: ref}
    else
      {:error, reason} ->
        Logger.warning("trigger registry LISTEN setup failed: #{inspect(reason)}")
        state
    end
  end

  defp notification_config do
    Repo.config()
    |> Keyword.take([
      :database,
      :hostname,
      :port,
      :username,
      :password,
      :socket_dir,
      :parameters,
      :ssl,
      :ssl_opts,
      :types
    ])
  end

  defp create_table(name, options) do
    case :ets.whereis(name) do
      :undefined -> :ok
      tid -> :ets.delete(tid)
    end

    :ets.new(name, options)
  end

  defp table_lookup(table, key) do
    case :ets.whereis(table) do
      :undefined -> []
      _tid -> :ets.lookup(table, key)
    end
  end

  defp schedule_refresh(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :refresh, interval_ms)
  end

  defp schedule_refresh(_interval_ms), do: :ok

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)
end
